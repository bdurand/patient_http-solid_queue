# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Tracks in-flight requests in the database for crash recovery.
    #
    # The registry keeps an Active Record row for each in-flight request, with
    # its heartbeat time and its Active Job. If a process crashes, another
    # process finds the orphaned requests and re-enqueues their jobs. A
    # distributed lock lets only one process at a time look for orphaned
    # requests.
    #
    # Each entry has a registry ID in the format
    # `hostname:pid:hex/request-uuid`:
    #
    # - `hostname`: The host name, with colons and slashes replaced by dashes.
    # - `pid`: The process ID.
    # - `hex`: 16 random hex characters that make the ID unique.
    # - `request-uuid`: The request ID.
    class TaskMonitor
      # Name of the garbage collection lock row.
      GC_LOCK_NAME = "gc"

      # @return [Configuration] The gem configuration.
      attr_reader :config

      # Creates a task monitor for this process.
      #
      # @param config [Configuration] The gem configuration.
      # @param max_connections [#call, nil] A callable that returns the total
      #   maximum number of connections for the process. Defaults to the
      #   configuration's value. With named processors, the module passes the
      #   sum across all processors.
      def initialize(config, max_connections: nil)
        @config = config
        @max_connections_source = max_connections || -> { config.max_connections }
        hostname = ::Socket.gethostname.force_encoding("UTF-8").tr(":/", "-")
        pid = ::Process.pid
        @lock_identifier = "#{hostname}:#{pid}:#{SecureRandom.hex(8)}".freeze
      end

      # Records a request as in flight in the database.
      #
      # Runs on the caller's thread through the `request_enqueued` observer
      # event. Errors propagate, so a task is never accepted without a durable
      # record. The processor rejects the task, and the enqueue raises to the
      # caller. The error is wrapped in `RegistrationError` so the job retries
      # instead of failing, because the usual cause is a transient database
      # issue.
      #
      # @param task [PatientHttp::RequestTask] The request task to register.
      # @raise [RegistrationError] If the record can't be written.
      # @return [void]
      def register(task)
        job_payload = task.task_handler.active_job_data.to_json
        task_id = full_task_id(task.id)
        now = Time.current

        with_connection do
          InflightRequest.create!(
            task_id: task_id,
            process_id: @lock_identifier,
            job_payload: job_payload,
            heartbeat_at: now,
            created_at: now
          )
        end
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to register task #{task_id}: #{e.class} - #{e.message}")
        raise RegistrationError.new("Failed to register task #{task_id}: #{e.class} - #{e.message}")
      end

      # Removes a request from the registry.
      #
      # @param task [PatientHttp::RequestTask] The request task.
      # @return [void]
      def unregister(task)
        task_id = full_task_id(task.id)
        with_connection do
          InflightRequest.where(task_id: task_id).delete_all
        end
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to unregister task #{task_id}: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Releases a request from this process, so the orphan collector
      # re-enqueues it on its next pass.
      #
      # Use this when a result can't be delivered. This process no longer
      # tracks the request, so its record must not look like it belongs to a
      # live process. Orphan collection skips records whose process is still
      # registered, which would strand the request until this process exits.
      #
      # @param task [PatientHttp::RequestTask] The request task to release.
      # @return [void]
      def release(task)
        task_id = full_task_id(task.id)
        with_connection do
          InflightRequest.where(task_id: task_id).update_all(
            process_id: released_process_id,
            heartbeat_at: Time.at(0).utc
          )
        end
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to release task #{task_id}: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Updates the heartbeat times of requests in one query.
      #
      # @param task_ids [Array<String>] The request IDs.
      # @return [void]
      def update_heartbeats(task_ids)
        return if task_ids.empty?

        full_ids = task_ids.map { |id| full_task_id(id) }
        with_connection do
          InflightRequest.where(task_id: full_ids).update_all(heartbeat_at: Time.current)
        end
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to update heartbeats: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Creates or refreshes this process's registration.
      #
      # @return [void]
      def ping_process
        max_connections = @max_connections_source.call

        with_connection do
          ProcessRegistration.upsert(
            {process_id: @lock_identifier, max_connections: max_connections, last_seen_at: Time.current},
            unique_by: upsert_unique_by(:process_id)
          )
        end
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to ping process: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Removes this process from the process registrations.
      #
      # @return [void]
      def remove_process
        with_connection do
          ProcessRegistration.where(process_id: @lock_identifier).delete_all
        end
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to remove process: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Tries to acquire the distributed garbage collection lock.
      #
      # A single semaphore row with pessimistic locking makes sure that only
      # one process at a time can claim the lock.
      #
      # @return [Boolean] `true` if the lock was acquired. `false` if another
      #   process holds an unexpired lock, or if garbage collection ran within
      #   the last `heartbeat_interval` seconds.
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

      # Releases the garbage collection lock if this process holds it, and
      # records the time in `last_gc_at`.
      #
      # @return [void]
      def release_gc_lock
        GcLock.where(lock_name: GC_LOCK_NAME, lock_holder: @lock_identifier)
          .update_all(last_gc_at: Time.current, lock_holder: nil, acquired_at: nil, expires_at: nil)
      rescue => e
        @config.logger&.error("[PatientHttp::SolidQueue] Failed to release GC lock: #{e.message}")
        raise if PatientHttp.testing?
      end

      # Finds orphaned requests and re-enqueues them.
      #
      # @param orphan_threshold_seconds [Numeric] The number of seconds without
      #   a heartbeat after which a request is considered orphaned.
      # @param logger [Logger] The logger for output.
      # @return [Integer] The number of orphaned requests re-enqueued.
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

      # Returns the registry ID for a request. The registry ID includes this
      # process's ID.
      #
      # @param task_id [String] The request ID.
      # @return [String] The registry ID.
      def full_task_id(task_id)
        "#{@lock_identifier}/#{task_id}"
      end

      # Returns whether a request is in the registry.
      #
      # @param task [PatientHttp::RequestTask] The request task.
      # @return [Boolean] `true` if the request is registered.
      # @api private
      def registered?(task)
        with_connection do
          InflightRequest.where(task_id: full_task_id(task.id)).exists?
        end
      end

      # Deletes all records. Works only in test mode.
      #
      # @raise [RuntimeError] If called outside test mode.
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

      # Checks out a database connection only for the duration of the work, so
      # the gem's threads don't hold pool connections between operations. The
      # gem's threads are the completion workers and the monitor thread.
      def with_connection(&block)
        Record.connection_pool.with_connection(&block)
      end

      # Process identifier stamped on released records. It is never registered
      # in the process table, so orphan collection always considers it dead.
      def released_process_id
        "#{@lock_identifier}:released"
      end

      def ensure_gc_lock_row!
        GcLock.insert_all([{lock_name: GC_LOCK_NAME}])
      end

      # Returns the conflict target for an upsert. MySQL doesn't support an
      # explicit conflict target. It resolves conflicts through the table's
      # unique indexes with `ON DUPLICATE KEY UPDATE`. Adapters that support
      # conflict targets, such as PostgreSQL and SQLite, require one.
      #
      # @param column [Symbol] The unique column to use as the conflict target.
      # @return [Symbol, nil] The column, or `nil` if the adapter doesn't allow
      #   a target.
      def upsert_unique_by(column)
        Record.connection.supports_insert_conflict_target? ? column : nil
      end

      # Re-enqueues one orphaned record.
      #
      # The method claims the record with an update that matches its exact
      # heartbeat, which handles race conditions. If the heartbeat changed
      # between the read and the claim, the update matches no rows and the
      # method skips the record. The claim refreshes the heartbeat before the
      # job is enqueued. If the process crashes during recovery, the record
      # goes stale again and a later garbage collection pass retries it, so the
      # request isn't lost. The record is deleted only after the job is
      # enqueued.
      #
      # @param record [InflightRequest] The orphaned record.
      # @param threshold [Time] The heartbeat cutoff. Only records with an
      #   older heartbeat are orphaned.
      # @param logger [Logger] The logger for output.
      # @return [Boolean] `true` if the record was re-enqueued.
      def reenqueue_orphaned_record(record, threshold, logger)
        # Atomically claim only if still orphaned (heartbeat unchanged). The dead
        # process_id is left in place so a failed recovery becomes orphaned again.
        claimed = InflightRequest
          .where(task_id: record.task_id, heartbeat_at: record.heartbeat_at)
          .where("heartbeat_at < ?", threshold)
          .update_all(heartbeat_at: Time.current)

        return false if claimed == 0

        job_data = JSON.parse(record.job_payload)
        ActiveJob::Base.deserialize(job_data).tap { |j| j.executions = 0 }.enqueue

        InflightRequest.where(task_id: record.task_id).delete_all

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
