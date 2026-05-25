# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Job that invokes callback services for HTTP request results.
    #
    # Receives serialized Response or Error data and invokes the appropriate
    # callback service method (+on_complete+ or +on_error+).
    #
    # @api private
    class CallbackJob < ActiveJob::Base
      # Clean up externally stored payloads when job exhausts all retries.
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

      # @param data [Hash] Response or Error data (possibly a storage reference)
      # @param result_type [String] "response" or "error" indicating the type of result
      # @param callback_service_name [String] Fully qualified callback service class name
      def perform(data, result_type, callback_service_name)
        callback_service_class = PatientHttp::ClassHelper.resolve_class_name(callback_service_name)
        callback_service = callback_service_class.new

        ref_data = PatientHttp::ExternalStorage.storage_ref?(data) ? data : nil
        actual_data = ref_data ? PatientHttp::SolidQueue.external_storage.fetch(data) : data
        actual_data = PatientHttp::SolidQueue.decrypt(actual_data)

        begin
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
        ensure
          PatientHttp::SolidQueue.external_storage.delete(ref_data) if ref_data
        end
      end
    end
  end
end
