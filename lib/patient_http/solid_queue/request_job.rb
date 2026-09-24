# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Job that hands HTTP requests to the async processor.
    #
    # `PatientHttp.get`, `PatientHttp.post`, and the other request methods
    # enqueue this job. When the request completes, `CallbackJob` calls the
    # callback service's `on_complete` or `on_error` method.
    #
    # @api private
    class RequestJob < ActiveJob::Base
      # Rejection due to backpressure is part of normal operation: retry until the
      # processor has capacity again. NotRunningError covers jobs that run during
      # the narrow window when the processor is draining or stopping.
      # UnknownProcessorError covers rolling deploys where a job names a processor
      # profile that an old process has not configured yet.
      retry_on PatientHttp::MaxCapacityError, PatientHttp::NotRunningError,
        PatientHttp::UnknownProcessorError, wait: :polynomially_longer, attempts: :unlimited

      # A registry write failure is usually a transient database issue, so give
      # it a bounded number of retries before the job is marked failed.
      retry_on PatientHttp::SolidQueue::RegistrationError, wait: :polynomially_longer, attempts: 10

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

      # Runs the HTTP request on a processor.
      #
      # @param data [Hash] The serialized request, or a reference to it in
      #   external storage. The request can be encrypted.
      # @param callback_service_name [String] The fully qualified callback
      #   service class name.
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx
      #   responses as errors. If `nil`, uses the processor profile's
      #   `raise_error_responses` option.
      # @param callback_args [Hash, nil] The arguments to pass to the callback.
      # @param request_id [String, nil] The request ID.
      # @param processor_name [String, nil] The name of the processor profile
      #   that runs the request. If `nil`, uses the processor set on the
      #   request, then the default processor. Jobs enqueued by earlier
      #   versions of the gem don't have this argument.
      # @return [void]
      def perform(data, callback_service_name, raise_error_responses, callback_args, request_id, processor_name = nil)
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
          request_id: request_id,
          processor_name: processor_name
        )
      end
    end
  end
end
