# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Task handler that uses Active Job to deliver results and retry requests.
    #
    # - A `CallbackJob` delivers each result to the callback service.
    # - Large payloads are written to external storage before the job is
    #   enqueued.
    # - A retry enqueues the original Active Job again.
    class TaskHandler < PatientHttp::TaskHandler
      # @return [Hash] The serialized Active Job that made the request.
      attr_reader :active_job_data

      # Creates a task handler for an Active Job.
      #
      # @param active_job_data [Hash] The serialized Active Job that made the
      #   request.
      def initialize(active_job_data)
        @active_job_data = active_job_data
      end

      # Enqueues a `CallbackJob` that calls the callback service's `on_complete`
      # method. A large response is written to external storage first.
      #
      # @param response [PatientHttp::Response] The HTTP response.
      # @param callback [String] The callback service class name.
      # @return [void]
      def on_complete(response, callback)
        data = store_if_needed(response.as_json)
        CallbackJob.perform_later(data, "response", callback)
        delete_stored_request_payload
      end

      # Enqueues a `CallbackJob` that calls the callback service's `on_error`
      # method. A large error is written to external storage first.
      #
      # @param error [PatientHttp::Error] The error.
      # @param callback [String] The callback service class name.
      # @return [void]
      def on_error(error, callback)
        data = store_if_needed(error.as_json)
        CallbackJob.perform_later(data, "error", callback)
        delete_stored_request_payload
      end

      # Re-enqueues the original Active Job with its execution count reset.
      #
      # @return [ActiveJob::Base, false] The enqueued job, or `false` if it
      #   wasn't enqueued.
      def retry
        ActiveJob::Base.deserialize(@active_job_data).tap { |j| j.executions = 0 }.enqueue
      end

      # Returns the Active Job ID.
      #
      # @return [String] The job ID.
      def job_id
        @active_job_data["job_id"]
      end

      # Returns the class of the Active Job.
      #
      # @return [Class] The job class.
      def worker_class
        PatientHttp::ClassHelper.resolve_class_name(@active_job_data["job_class"])
      end

      private

      # Deletes the externally stored request payload after the request
      # finishes. The payload must stay available until then, because Active Job
      # retries, processor shutdown retries, and crash recovery can enqueue the
      # job again. Applies only to `RequestJob` jobs, because other job types
      # manage their own arguments.
      #
      # @return [void]
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
