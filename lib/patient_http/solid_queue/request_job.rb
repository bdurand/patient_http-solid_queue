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
      # Capture the Active Job serialized hash into Context so RequestExecutor can use it.
      around_perform do |job, block|
        PatientHttp::SolidQueue::Context.with_job(job.serialize) { block.call }
      end

      # @param data [Hash] Request data (possibly a storage reference)
      # @param callback_service_name [String] Fully qualified callback service class name
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx responses as errors
      # @param callback_args [Hash, nil] Arguments to pass to the callback
      # @param request_id [String, nil] Unique request ID for tracking
      def perform(data, callback_service_name, raise_error_responses, callback_args, request_id)
        ref_data = PatientHttp::ExternalStorage.storage_ref?(data) ? data : nil
        actual_data = ref_data ? PatientHttp::SolidQueue.external_storage.fetch(data) : data
        actual_data = PatientHttp::SolidQueue.configuration.decrypt(actual_data)

        request = PatientHttp::Request.load(actual_data)
        active_job_data = PatientHttp::SolidQueue::Context.current_job

        begin
          RequestExecutor.execute(
            request,
            callback: callback_service_name,
            raise_error_responses: raise_error_responses,
            callback_args: callback_args,
            active_job_data: active_job_data,
            request_id: request_id
          )
        ensure
          PatientHttp::SolidQueue.external_storage.delete(ref_data) if ref_data
        end
      end
    end
  end
end
