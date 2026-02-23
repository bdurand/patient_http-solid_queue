# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Helper methods for executing HTTP requests asynchronously.
    class RequestExecutor
      class << self
        # Execute the request directly on the async processor.
        #
        # @param request [PatientHttp::Request] the HTTP request to execute
        # @param callback [Class, String] Callback service class or its fully qualified class name
        # @param active_job_data [Hash, nil] Active Job serialized hash with "job_class" and "arguments" keys
        # @param synchronous [Boolean] If true, runs the request inline (for testing)
        # @param callback_args [#to_h, nil] Arguments to pass to callback
        # @param raise_error_responses [Boolean] If true, treats non-2xx responses as errors
        # @param request_id [String, nil] Unique request ID for tracking
        # @return [String] the request ID
        # @api private
        def execute(
          request,
          callback:,
          active_job_data: nil,
          synchronous: false,
          callback_args: nil,
          raise_error_responses: false,
          request_id: nil
        )
          active_job_data = validate_active_job_data(active_job_data)
          task_handler = TaskHandler.new(active_job_data)
          config = PatientHttp::SolidQueue.configuration

          task = PatientHttp::RequestTask.new(
            request: request,
            task_handler: task_handler,
            callback: callback,
            callback_args: callback_args,
            raise_error_responses: raise_error_responses,
            id: request_id,
            default_max_redirects: config.max_redirects
          )

          if synchronous || async_disabled?
            PatientHttp::SynchronousExecutor.new(
              task,
              config: config,
              on_complete: ->(response) { PatientHttp::SolidQueue.invoke_completion_callbacks(response) },
              on_error: ->(error) { PatientHttp::SolidQueue.invoke_error_callbacks(error) }
            ).call
            return task.id
          end

          processor = PatientHttp::SolidQueue.processor
          unless processor&.running?
            raise PatientHttp::NotRunningError, "Cannot enqueue request: processor is not running"
          end

          processor.enqueue(task)
          task.id
        end

        private

        def validate_active_job_data(active_job_data)
          active_job_data ||= PatientHttp::SolidQueue::Context.current_job
          raise ArgumentError, "active_job_data is required" if active_job_data.nil?
          raise ArgumentError, "active_job_data must be a Hash, got: #{active_job_data.class}" unless active_job_data.is_a?(Hash)
          raise ArgumentError, "active_job_data must have 'job_class' key" unless active_job_data.key?("job_class")
          raise ArgumentError, "active_job_data must have 'arguments' array" unless active_job_data["arguments"].is_a?(Array)
          active_job_data
        end

        def async_disabled?
          PatientHttp.testing?
        end
      end
    end
  end
end
