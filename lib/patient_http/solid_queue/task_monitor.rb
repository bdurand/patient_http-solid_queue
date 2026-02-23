# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Manages inflight request tracking in the database for crash recovery.
    #
    # This class maintains Active Record records for each in-flight request.
    # It provides distributed locking for orphan detection and automatic
    # re-enqueueing of requests interrupted by process crashes.
    #
    # Task ID format: "hostname:pid:hex/request-uuid"
    # - hostname: sanitized hostname (colons and slashes replaced with dashes)
    # - pid: process ID
    # - hex: 8-character random hex for uniqueness
    # - request-uuid: unique identifier for the request
    class TaskMonitor
      GC_LOCK_NAME = "gc"

      # @return [Configuration] the configuration object
      attr_reader :config

      def initialize(config)
        @config = config
        hostname = ::Socket.gethostname.force_encoding("UTF-8").tr(":/", "-")
        pid = ::Process.pid
        @lock_identifier = "#{hostname}:#{pid}:#{SecureRandom.hex(8)}".freeze
      end

      # Register a request as inflight in the database.
      #
      # @param task [PatientHttp::RequestTask] the request task to register
      # @return [void]
      def register(task)
        job_payload = task.task_handler.active_job_data.to_json
        task_id = full_task_id(task.id)
        now = Time.current

        InflightRequest.create!(
          task_id: task_id,
          process_id: @lock_identifier,
          job_payload: job_payload,
          heartbeat_at: now,
          created_at: now
        )
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to register task #{task_id}: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Unregister a request from the database (called when request completes).
      #
      # @param task [PatientHttp::RequestTask] the request task to unregister
      # @return [void]
      def unregister(task)
        task_id = full_task_id(task.id)
        InflightRequest.where(task_id: task_id).delete_all
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to unregister task #{task_id}: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Update heartbeat timestamps for multiple requests in a single operation.
      #
      # @param task_ids [Array<String>] the request IDs to update
      # @return [void]
      def update_heartbeats(task_ids)
        return if task_ids.empty?

        full_ids = task_ids.map { |id| full_task_id(id) }
        InflightRequest.where(task_id: full_ids).update_all(heartbeat_at: Time.current)
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to update heartbeats: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Record or refresh this process's registration.
      #
      # @return [void]
      def ping_process
        ProcessRegistration.upsert(
          {process_id: @lock_identifier, max_connections: @config.max_connections, last_seen_at: Time.current},
          unique_by: :process_id
        )
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to ping process: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Remove this process's registration.
      #
      # @return [void]
      def remove_process
        ProcessRegistration.where(process_id: @lock_identifier).delete_all
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to remove process: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Try to acquire the distributed garbage collection lock.
      #
      # Uses a single semaphore row and pessimistic locking to ensure only one
      # process can claim the lock at a time.
      # Returns false if another process holds a non-expired lock, or if GC was
      # run recently (within heartbeat_interval).
      #
      # @return [Boolean] true if lock acquired, false otherwise
      def acquire_gc_lock
        now = Time.current
        expires_at = now + gc_lock_ttl.seconds
        acquired = false

        ensure_gc_lock_row!

        GcLock.transaction do
          lock = GcLock.lock.find_by!(lock_name: GC_LOCK_NAME)

          recent_gc = lock.last_gc_at && lock.last_gc_at > (now - @config.heartbeat_interval)
          next if recent_gc

          lock_held = lock.lock_holder.present? && lock.expires_at.present? && lock.expires_at > now
          next if lock_held

          lock.update!(
            lock_holder: @lock_identifier,
            acquired_at: now,
            expires_at: expires_at
          )
          acquired = true
        end

        acquired
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to acquire GC lock: #{e.message}")
        raise if PatientHttp.testing?
        false
      end

      # Release the garbage collection lock if held by this process, and record last_gc_at.
      #
      # @return [void]
      def release_gc_lock
        GcLock.where(lock_name: GC_LOCK_NAME, lock_holder: @lock_identifier)
          .update_all(last_gc_at: Time.current, lock_holder: nil, acquired_at: nil, expires_at: nil)
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to release GC lock: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Find and re-enqueue orphaned requests.
      #
      # @param orphan_threshold_seconds [Numeric] age threshold for considering a request orphaned
      # @param logger [Logger] logger for output
      # @return [Integer] number of orphaned requests re-enqueued
      def cleanup_orphaned_requests(orphan_threshold_seconds, logger)
        threshold = Time.current - orphan_threshold_seconds.seconds

        prune_stale_process_registrations(threshold)

        # Get process IDs with a recent heartbeat
        active_process_ids = ProcessRegistration.where("last_seen_at >= ?", threshold).pluck(:process_id)

        # Find stale requests from processes not in the active set
        orphaned = InflightRequest
          .where("heartbeat_at < ?", threshold)
          .where.not(process_id: active_process_ids)
          .to_a

        return 0 if orphaned.empty?

        reenqueued_count = 0

        orphaned.each do |record|
          reenqueued_count += 1 if reenqueue_orphaned_record(record, threshold, logger)
        end

        reenqueued_count
      end

      # Build unique task ID for a request task that includes process identifier.
      #
      # @param task_id [String] the request task ID
      # @return [String] the unique task ID
      def full_task_id(task_id)
        "#{@lock_identifier}/#{task_id}"
      end

      # Check if a task is registered in the inflight table.
      #
      # @param task [PatientHttp::RequestTask] the request task
      # @return [Boolean]
      # @api private
      def registered?(task)
        InflightRequest.where(task_id: full_task_id(task.id)).exists?
      end

      # Clear all records. Only allowed in test environment.
      #
      # @raise [RuntimeError] if called outside of test environment
      # @return [void]
      # @api private
      def self.clear_all!
        unless PatientHttp.testing?
          raise "clear_all! is only allowed in test environment"
        end

        InflightRequest.delete_all
        ProcessRegistration.delete_all
        GcLock.delete_all
      end

      private

      def ensure_gc_lock_row!
        GcLock.insert_all([{lock_name: GC_LOCK_NAME}], unique_by: :lock_name)
      end

      # Re-enqueue a single orphaned record atomically.
      #
      # Uses a delete-by-exact-heartbeat to handle race conditions: if the
      # heartbeat was updated between our read and the delete, the delete
      # returns 0 rows and we skip re-enqueueing.
      #
      # @param record [InflightRequest] the orphaned record
      # @param threshold [Float] heartbeat threshold (only records below this are orphaned)
      # @param logger [Logger] logger for output
      # @return [Boolean] true if successfully re-enqueued
      def reenqueue_orphaned_record(record, threshold, logger)
        # Atomically remove only if still orphaned (heartbeat unchanged)
        deleted = InflightRequest
          .where(task_id: record.task_id, heartbeat_at: record.heartbeat_at)
          .where("heartbeat_at < ?", threshold)
          .delete_all

        return false if deleted == 0

        job_data = JSON.parse(record.job_payload)
        ActiveJob::Base.deserialize(job_data).tap { |j| j.executions = 0 }.enqueue

        logger&.info(
          "[PatientHttp::SolidQueue] Re-enqueued orphaned request #{record.task_id} to #{job_data["job_class"]}"
        )

        true
      rescue => e
        logger&.error(
          "[PatientHttp::SolidQueue] Failed to re-enqueue orphaned request #{record.task_id}: #{e.class} - #{e.message}"
        )
        false
      end

      def gc_lock_ttl
        [@config.heartbeat_interval * 2, 120].max
      end

      def prune_stale_process_registrations(threshold)
        ProcessRegistration.where("last_seen_at < ?", threshold).delete_all
      end
    end
  end
end
