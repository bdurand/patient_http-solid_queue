# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Job implementation of +PatientHttp::TaskHandler+.
    #
    # Handles task lifecycle events with Active Job:
    #
    # - Enqueues +CallbackJob+ to run completion and error callbacks.
    # - Stores large payloads in external storage before it enqueues a job.
    # - Retries a request by deserializing and re-enqueuing the original job.
    class TaskHandler < PatientHttp::TaskHandler
      # @return [Hash] The serialized Active Job hash for the job that made the
      #   request.
      attr_reader :active_job_data

      # Creates a task handler.
      #
      # @param active_job_data [Hash] The serialized Active Job hash for the job
      #   that made the request.
      def initialize(active_job_data)
        @active_job_data = active_job_data
      end

      # Enqueues a callback job for a completed request.
      #
      # @param response [PatientHttp::Response] The HTTP response.
      # @param callback [String] The callback service class name.
      # @return [void]
      def on_complete(response, callback)
        data = store_if_needed(response.as_json)
        CallbackJob.perform_later(data, "response", callback)
        delete_stored_request_payload
      end

      # Enqueues a callback job for a failed request.
      #
      # @param error [PatientHttp::Error] Information about the error.
      # @param callback [String] The callback service class name.
      # @return [void]
      def on_error(error, callback)
        data = store_if_needed(error.as_json)
        CallbackJob.perform_later(data, "error", callback)
        delete_stored_request_payload
      end

      # Re-enqueues the original job with its execution count reset.
      #
      # @return [ActiveJob::Base, false] The enqueued job, or +false+ if Active
      #   Job didn't enqueue it.
      def retry
        ActiveJob::Base.deserialize(@active_job_data).tap { |j| j.executions = 0 }.enqueue
      end

      # Returns the Active Job ID of the job that made the request.
      #
      # @return [String, nil] The job ID.
      def job_id
        @active_job_data["job_id"]
      end

      # Returns the class of the job that made the request.
      #
      # @return [Class] The job class.
      def worker_class
        PatientHttp::ClassHelper.resolve_class_name(@active_job_data["job_class"])
      end

      private

      # Deletes the externally stored request payload after the request
      # completes. Until then, the payload must stay available because Active
      # Job retries, processor shutdown retries, and crash recovery can
      # re-enqueue the job that references it. Applies only to +RequestJob+;
      # other job types manage their own arguments.
      def delete_stored_request_payload
        return unless @active_job_data["job_class"] == RequestJob.name

        data = @active_job_data["arguments"]&.first
        return unless PatientHttp::ExternalStorage.storage_ref?(data)

        PatientHttp::SolidQueue.external_storage.delete(data)
      rescue => e
        PatientHttp::SolidQueue.configuration.logger&.warn(
          "[PatientHttp::SolidQueue] Failed to delete stored request payload: #{e.class.name} #{e.message}".strip
        )
      end

      def store_if_needed(data)
        encrypted = PatientHttp::SolidQueue.encrypt(data)
        external_storage = PatientHttp::SolidQueue.external_storage
        if external_storage.enabled?
          external_storage.store(encrypted, max_size: PatientHttp::SolidQueue.configuration.payload_store_threshold)
        else
          encrypted
        end
      end
    end
  end
end
