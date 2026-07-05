# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Job that executes HTTP requests asynchronously.
    #
    # Enqueued when calling PatientHttp::SolidQueue.get, .post, etc.
    # On completion, the specified callback service's on_complete or on_error is
    # invoked via CallbackJob.
    #
    # @api private
    class RequestJob < ActiveJob::Base
      # Rejection due to backpressure is part of normal operation: retry until the
      # processor has capacity again. NotRunningError covers jobs that run during
      # the narrow window when the processor is draining or stopping.
      retry_on PatientHttp::MaxCapacityError, PatientHttp::NotRunningError, wait: :polynomially_longer, attempts: :unlimited

      # Capture the Active Job serialized hash into Context so RequestExecutor can use it.
      around_perform do |job, block|
        PatientHttp::SolidQueue::Context.with_job(job.serialize) { block.call }
      end

      # Clean up the externally stored request payload when the job is discarded.
      # The payload is normally deleted by TaskHandler when the request completes,
      # so this only fires for requests that never made it that far.
      after_discard do |job, _exception|
        PatientHttp::SolidQueue.external_storage.delete(job.arguments[0])
      rescue => e
        PatientHttp::SolidQueue.configuration.logger&.warn(
          "[PatientHttp::SolidQueue] Failed to delete stored payload for dead job: #{e.class.name} #{e.message}".strip
        )
      end

      # @param data [Hash] Request data (possibly a storage reference)
      # @param callback_service_name [String] Fully qualified callback service class name
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx responses as errors
      # @param callback_args [Hash, nil] Arguments to pass to the callback
      # @param request_id [String, nil] Unique request ID for tracking
      def perform(data, callback_service_name, raise_error_responses, callback_args, request_id)
        actual_data = PatientHttp::ExternalStorage.storage_ref?(data) ? PatientHttp::SolidQueue.external_storage.fetch(data) : data
        actual_data = PatientHttp::SolidQueue.decrypt(actual_data)

        request = PatientHttp::Request.load(actual_data)
        active_job_data = PatientHttp::SolidQueue::Context.current_job

        # The stored payload must not be deleted here: this job data is re-enqueued
        # for Active Job retries (e.g. MaxCapacityError), processor shutdown retries,
        # and crash recovery, all of which need to fetch the payload again.
        # TaskHandler deletes it when the request completes.
        RequestExecutor.execute(
          request,
          callback: callback_service_name,
          raise_error_responses: raise_error_responses,
          callback_args: callback_args,
          active_job_data: active_job_data,
          request_id: request_id
        )
      end
    end
  end
end
