# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Runs HTTP requests on the asynchronous processor.
    class RequestExecutor
      class << self
        # Sends a request to a processor. In test mode, or if +synchronous+ is
        # +true+, runs the request in the current thread instead.
        #
        # @param request [PatientHttp::Request] The HTTP request to run.
        # @param callback [Class, String] The callback service class, or its fully
        #   qualified class name.
        # @param active_job_data [Hash, nil] The serialized Active Job hash, with
        #   +"job_class"+ and +"arguments"+ keys. Defaults to the job in {Context}.
        # @param synchronous [Boolean] If +true+, runs the request in the current
        #   thread. Use this in tests.
        # @param callback_args [#to_h, nil] Arguments to pass to the callback.
        # @param raise_error_responses [Boolean] If +true+, treats non-2xx
        #   responses as errors.
        # @param request_id [String, nil] A unique request ID for tracking.
        # @param processor_name [Symbol, String, nil] The name of the processor
        #   profile that runs the request. Defaults to the request's processor
        #   name, or +:default+ if the request doesn't set one.
        # @return [String] The request ID.
        # @raise [ArgumentError] If +active_job_data+ is missing or invalid.
        # @raise [PatientHttp::UnknownProcessorError] If the processor profile
        #   isn't configured.
        # @raise [PatientHttp::NotRunningError] If the processor isn't running.
        # @raise [PatientHttp::MaxCapacityError] If the processor is at capacity.
        # @api private
        def execute(
          request,
          callback:,
          active_job_data: nil,
          synchronous: false,
          callback_args: nil,
          raise_error_responses: false,
          request_id: nil,
          processor_name: nil
        )
          active_job_data = validate_active_job_data(active_job_data)
          task_handler = TaskHandler.new(active_job_data)
          config = PatientHttp::SolidQueue.configuration

          # Resolve the processor profile up front so the task is built with
          # the options of the processor that will run it. An unknown name
          # falls back to the base configuration here and is reported below.
          name = (processor_name || request.processor || :default).to_sym
          profile_config = config.processor_profiles.key?(name) ? config.processor_config(name) : config

          task = PatientHttp::RequestTask.new(
            request: request,
            task_handler: task_handler,
            callback: callback,
            callback_args: callback_args,
            raise_error_responses: raise_error_responses,
            id: request_id,
            default_max_redirects: profile_config.max_redirects
          )

          if synchronous || async_disabled?
            PatientHttp::SynchronousExecutor.new(
              task,
              config: profile_config,
              on_complete: ->(response) { PatientHttp::SolidQueue.invoke_completion_callbacks(response) },
              on_error: ->(error) { PatientHttp::SolidQueue.invoke_error_callbacks(error) }
            ).call
            return task.id
          end

          # Look up the named processor. An unknown name raises so the job
          # lands in Active Job's retry mechanism instead of being dropped;
          # this covers rolling deploys where an old process has not
          # configured a new profile yet.
          processor = PatientHttp::SolidQueue.processor(name)
          if processor.nil? && !config.processor_profiles.key?(name)
            raise PatientHttp::UnknownProcessorError, "No processor profile configured for #{name.inspect}"
          end

          unless processor&.running?
            raise PatientHttp::NotRunningError, "Cannot enqueue request: processor is not running"
          end

          # Advisory capacity check before enqueueing. A real enqueue writes
          # the durable registry record before the authoritative capacity
          # check, so a full processor would pay a database insert and delete
          # just to be rejected. This peek rejects for free; the race where
          # capacity fills after the peek falls through to the normal
          # rejection path.
          unless processor.capacity_available?
            raise PatientHttp::MaxCapacityError,
              "Cannot enqueue request: processor #{name} is at max capacity (#{processor.config.max_connections} connections)"
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
