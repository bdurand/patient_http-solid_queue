# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Job implementation of TaskHandler.
    #
    # Handles task lifecycle operations using Active Job for job management:
    # - Completion and error callbacks are triggered via CallbackJob
    # - Large payloads are stored via ExternalStorage before enqueuing
    # - Job retry uses ActiveJob::Base.deserialize
    class TaskHandler < PatientHttp::TaskHandler
      attr_reader :active_job_data

      def initialize(active_job_data)
        @active_job_data = active_job_data
      end

      def on_complete(response, callback)
        data = store_if_needed(response.as_json)
        CallbackJob.perform_later(data, "response", callback)
      end

      def on_error(error, callback)
        data = store_if_needed(error.as_json)
        CallbackJob.perform_later(data, "error", callback)
      end

      def retry
        ActiveJob::Base.deserialize(@active_job_data).tap { |j| j.executions = 0 }.enqueue
      end

      def job_id
        @active_job_data["job_id"]
      end

      def worker_class
        PatientHttp::ClassHelper.resolve_class_name(@active_job_data["job_class"])
      end

      private

      def store_if_needed(data)
        encrypted = PatientHttp::SolidQueue.configuration.encrypt(data)
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
