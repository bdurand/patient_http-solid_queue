# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Job that passes HTTP request results to callback services.
    #
    # The job receives serialized response or error data and calls the
    # callback service's `on_complete` or `on_error` method.
    #
    # @api private
    class CallbackJob < ActiveJob::Base
      # Calls the `on_retries_exhausted` handler and deletes any externally
      # stored payload when Active Job discards the job.
      after_discard do |job, _exception|
        data = job.arguments[0]
        result_type = job.arguments[1]

        begin
          handler = PatientHttp::SolidQueue.configuration.on_retries_exhausted
          if handler && result_type == "error"
            actual_data = if PatientHttp::SolidQueue.external_storage.storage_ref?(data)
              PatientHttp::SolidQueue.external_storage.fetch(data)
            else
              data
            end
            actual_data = PatientHttp::SolidQueue.decrypt(actual_data)
            error = PatientHttp::Error.load(actual_data)
            handler.call(error)
          end
        rescue => e
          PatientHttp::SolidQueue.configuration.logger&.warn(
            "[PatientHttp::SolidQueue] on_retries_exhausted handler failed: #{e.class.name} #{e.message}".strip
          )
        end

        begin
          PatientHttp::SolidQueue.external_storage.delete(data)
        rescue => e
          PatientHttp::SolidQueue.configuration.logger&.warn(
            "[PatientHttp::SolidQueue] Failed to delete stored payload for dead job: #{e.class.name} #{e.message}".strip
          )
        end
      end

      # Loads the result and calls the callback service.
      #
      # @param data [Hash] The response or error data, or a reference to it in
      #   external storage.
      # @param result_type [String] The result type, either `"response"` or
      #   `"error"`.
      # @param callback_service_name [String] The fully qualified class name of
      #   the callback service.
      # @return [void]
      # @raise [ArgumentError] If the result type is unknown.
      def perform(data, result_type, callback_service_name)
        callback_service_class = PatientHttp::ClassHelper.resolve_class_name(callback_service_name)
        callback_service = callback_service_class.new

        ref_data = PatientHttp::ExternalStorage.storage_ref?(data) ? data : nil
        actual_data = ref_data ? PatientHttp::SolidQueue.external_storage.fetch(data) : data
        actual_data = PatientHttp::SolidQueue.decrypt(actual_data)

        if result_type == "response"
          response = PatientHttp::Response.load(actual_data)
          PatientHttp::SolidQueue.invoke_completion_callbacks(response)
          callback_service.on_complete(response)
        elsif result_type == "error"
          error = PatientHttp::Error.load(actual_data)
          PatientHttp::SolidQueue.invoke_error_callbacks(error)
          callback_service.on_error(error)
        else
          raise ArgumentError, "Unknown result_type: #{result_type}"
        end

        # Only delete the stored payload after the callback succeeds so that
        # retries can still fetch it. Discarded jobs are cleaned up by the
        # after_discard hook.
        PatientHttp::SolidQueue.external_storage.delete(ref_data) if ref_data
      end
    end
  end
end
