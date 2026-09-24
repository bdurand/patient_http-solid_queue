# frozen_string_literal: true

require "patient_http"
require "solid_queue"

module PatientHttp
  # Runs HTTP requests from Solid Queue jobs on an async I/O processor.
  #
  # The processor runs in the Solid Queue worker process. Worker threads hand
  # off long-running HTTP requests to it and are free to run other jobs while
  # the requests are in flight.
  #
  # This module manages the processors for the current process. It starts one
  # processor for each configured processor profile when a Solid Queue worker
  # starts, and stops them when the worker stops. All processors in a process
  # share one crash-recovery monitor.
  #
  # @example Make a request
  #   PatientHttp.get(
  #     "https://api.example.com/users/123",
  #     callback: MyCallback,
  #     callback_args: {user_id: 123}
  #   )
  #
  # @example Define a callback service
  #   class MyCallback
  #     def on_complete(response)
  #       user_id = response.callback_args[:user_id]
  #       User.find(user_id).update!(data: response.json)
  #     end
  #
  #     def on_error(error)
  #       Rails.logger.error("Request failed: #{error.message}")
  #     end
  #   end
  module SolidQueue
    # The gem version.
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

    # Raised when the crash recovery registry entry for a request can't be
    # written. The processor rejects the request instead of accepting it
    # without a durable record, and the job retries.
    class RegistrationError < StandardError; end

    autoload :CallbackJob, File.join(__dir__, "solid_queue/callback_job")
    autoload :Configuration, File.join(__dir__, "solid_queue/configuration")
    autoload :Context, File.join(__dir__, "solid_queue/context")
    autoload :GcLock, File.join(__dir__, "solid_queue/gc_lock")
    autoload :InflightRequest, File.join(__dir__, "solid_queue/inflight_request")
    autoload :ProcessorObserver, File.join(__dir__, "solid_queue/processor_observer")
    autoload :ProcessRegistration, File.join(__dir__, "solid_queue/process_registration")
    autoload :Record, File.join(__dir__, "solid_queue/record")
    autoload :RequestExecutor, File.join(__dir__, "solid_queue/request_executor")
    autoload :RequestJob, File.join(__dir__, "solid_queue/request_job")
    autoload :LifecycleHooks, File.join(__dir__, "solid_queue/lifecycle_hooks")
    autoload :TaskHandler, File.join(__dir__, "solid_queue/task_handler")
    autoload :TaskMonitor, File.join(__dir__, "solid_queue/task_monitor")
    autoload :TaskMonitorThread, File.join(__dir__, "solid_queue/task_monitor_thread")

    @processors = {}
    @after_completion_callbacks = []
    @after_error_callbacks = []
    @external_storage = nil
    @request_handler = nil
    @lifecycle_mutex = Mutex.new
    @task_monitor = nil
    @monitor_thread = nil

    class << self
      # Sets the configuration. Intended for tests.
      #
      # `PatientHttp` stores the configuration, so this method assigns it there.
      #
      # @param config [Configuration, nil] The configuration, or `nil` to build a
      #   new one on next use.
      # @return [void]
      def configuration=(config)
        PatientHttp.default_configuration = config
      end

      # Yields the configuration to a block.
      #
      # Every call yields the same configuration object, so options accumulate.
      # Several initializers can each set options without overwriting one
      # another. `PatientHttp.configure` calls this method, so application code
      # can use either one.
      #
      # @example
      #   PatientHttp.configure do |config|
      #     config.max_connections = 512
      #   end
      #
      # @yield [config] The block that sets configuration options.
      # @yieldparam config [Configuration] The configuration.
      # @return [Configuration] The configuration.
      def configure
        config = configuration
        yield(config) if block_given?
        config
      end

      # Returns the configuration for this process, and creates it on first use.
      #
      # `PatientHttp` stores the configuration, so this method and
      # `PatientHttp.configuration` return the same object. As a result, secrets
      # registered with `PatientHttp.register_secret` reach the configuration
      # that the processors use, regardless of load order.
      #
      # @return [Configuration] The configuration.
      def configuration
        PatientHttp.configuration
      end

      # Builds a new configuration. `PatientHttp` calls this method when it
      # creates the configuration for this process.
      #
      # @return [Configuration] The new configuration.
      # @api private
      def new_configuration
        Configuration.new
      end

      # Resets the configuration to the defaults. Intended for tests.
      #
      # @return [Configuration] The new configuration.
      def reset_configuration!
        @external_storage = nil
        PatientHttp.default_configuration = nil
        configuration
      end

      # Registers a block to run after each request completes. Use it for
      # monitoring. Blocks run in the order they're registered.
      #
      # @example
      #   PatientHttp::SolidQueue.after_completion do |response|
      #     StatsD.timing("patient_http.duration", response.duration * 1000)
      #   end
      #
      # @yield [response] The block to run.
      # @yieldparam response [PatientHttp::Response] The HTTP response.
      # @return [void]
      def after_completion(&block)
        @after_completion_callbacks << block
      end

      # Registers a block to run after each request error. Use it for
      # monitoring. Blocks run in the order they're registered.
      #
      # @example
      #   PatientHttp::SolidQueue.after_error do |error|
      #     StatsD.increment("patient_http.error.#{error.error_type}")
      #   end
      #
      # @yield [error] The block to run.
      # @yieldparam error [PatientHttp::Error] The error.
      # @return [void]
      def after_error(&block)
        @after_error_callbacks << block
      end

      # Returns whether any processor is running.
      #
      # @return [Boolean] `true` if any processor is running.
      def running?
        @processors.values.any?(&:running?)
      end

      # Returns whether any processor is draining. A draining processor doesn't
      # accept new requests but continues to run in-flight requests.
      #
      # @return [Boolean] `true` if any processor is draining.
      def draining?
        @processors.values.any?(&:draining?)
      end

      # Returns whether any processor is stopping.
      #
      # @return [Boolean] `true` if any processor is stopping.
      def stopping?
        @processors.values.any?(&:stopping?)
      end

      # Returns whether all processors are stopped.
      #
      # @return [Boolean] `true` if all processors are stopped or none has
      #   started.
      def stopped?
        @processors.values.all?(&:stopped?)
      end

      # Returns the external storage for request and result payloads. The
      # storage is rebuilt when the configuration is replaced.
      #
      # @return [PatientHttp::ExternalStorage] The external storage.
      # @api private
      def external_storage
        config = configuration
        storage = @external_storage
        unless storage&.config.equal?(config)
          storage = PatientHttp::ExternalStorage.new(config)
          @external_storage = storage
        end
        storage
      end

      # Runs an HTTP request asynchronously and calls the callback service with
      # the result.
      #
      # Application code normally uses the `PatientHttp` module methods instead,
      # such as `PatientHttp.get`, `PatientHttp.post`, or the
      # PatientHttp::RequestHelper mixin. Those methods take the same options and
      # keep application code independent of the job system. They call this
      # method through the registered request handler.
      #
      # @param request [PatientHttp::Request] The HTTP request.
      # @param callback [Class, String] The callback service class, or its fully
      #   qualified name. The class must define `on_complete` and `on_error`
      #   instance methods.
      # @param callback_args [#to_h, nil] The arguments to pass to the callback.
      #   Values must be JSON-native types: `nil`, `true`, `false`, String,
      #   Integer, Float, Array, or Hash. Hash keys are converted to strings. The
      #   callback reads the arguments from `response.callback_args` or
      #   `error.callback_args` with symbol or string keys.
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx
      #   responses as errors and call `on_error` instead of `on_complete`. If
      #   `nil`, uses the `raise_error_responses` configuration option.
      # @param processor [Symbol, String, nil] The name of the processor profile
      #   that runs the request. If `nil`, uses the processor set on the request,
      #   then `:default`.
      # @return [String] The request ID.
      # @raise [PatientHttp::UnknownProcessorError] If the processor profile
      #   isn't configured.
      def execute(request, callback:, callback_args: nil, raise_error_responses: nil, processor: nil)
        PatientHttp::CallbackValidator.validate!(callback)
        callback_name = callback.is_a?(Class) ? callback.name : callback.to_s
        callback_args = PatientHttp::CallbackValidator.validate_callback_args(callback_args)
        request_id = SecureRandom.uuid
        processor_name = (processor || request.processor || :default).to_s

        # Catch a misspelled profile name at the call site. A job that names an
        # unconfigured profile is retried instead, which covers rolling deploys
        # where the executing process is older than the enqueueing one.
        unless configuration.processor_profiles.key?(processor_name.to_sym)
          raise PatientHttp::UnknownProcessorError.new("No processor profile configured for #{processor_name.inspect}")
        end

        profile_config = processor_config_for(processor_name)

        # The PatientHttp module methods pass nil when the caller did not ask for a
        # specific behavior, so fall back to the processor profile's setting.
        raise_error_responses = profile_config.raise_error_responses if raise_error_responses.nil?

        encrypted = encrypt(request.as_json)

        data = if external_storage.enabled?
          external_storage.store(encrypted, max_size: profile_config.payload_store_threshold)
        else
          encrypted
        end

        RequestJob.perform_later(data, callback_name, raise_error_responses, callback_args, request_id, processor_name)

        request_id
      end

      # Starts a processor for each configured processor profile. Also starts
      # the crash-recovery monitor that the processors share. The Solid Queue
      # lifecycle hooks call this method when a Solid Queue worker starts.
      #
      # @return [void]
      def start
        @lifecycle_mutex.synchronize do
          return if @processors.any? && !@processors.values.all?(&:stopped?)

          @task_monitor ||= TaskMonitor.new(
            configuration,
            max_connections: -> { @processors.values.sum { |p| p.config.max_connections } }
          )

          @processors = {}
          configuration.processor_profiles.each_key do |name|
            processor = PatientHttp::Processor.new(configuration.processor_config(name), name: name)
            processor.observe(ProcessorObserver.new(processor, task_monitor: @task_monitor))
            @processors[name] = processor
          end
          @processors.each_value(&:start)

          # A previous run can leave a monitor thread behind if the processors
          # stopped without going through #stop.
          @monitor_thread&.stop

          @monitor_thread = TaskMonitorThread.new(
            configuration,
            @task_monitor,
            -> { @processors.values.flat_map(&:tracked_request_ids) }
          )
          @monitor_thread.start
        end

        register_handler
      end

      # Drains all processors. A draining processor doesn't accept new requests
      # but continues to run in-flight requests.
      #
      # @return [void]
      def quiet
        @lifecycle_mutex.synchronize do
          return unless running?

          @processors.each_value(&:drain)
        end
      end

      # Stops all processors and the services they share. The Solid Queue
      # lifecycle hooks call this method when a Solid Queue worker stops.
      #
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests to finish. If `nil`, uses the `shutdown_timeout`
      #   configuration option.
      # @return [void]
      def stop(timeout: nil)
        @lifecycle_mutex.synchronize do
          return if @processors.empty?

          stop_processors(timeout: timeout)
          @processors = {}
          shutdown_shared_services
        end
      end

      # Stops all processors and resets all state. Intended for tests.
      #
      # @return [void]
      # @api private
      def reset!
        @lifecycle_mutex.synchronize do
          stop_processors(timeout: 0)
          @processors = {}
          shutdown_shared_services
        end
        @external_storage = nil
        @after_completion_callbacks = []
        @after_error_callbacks = []
        PatientHttp.default_configuration = nil
        # Restore the state a freshly loaded process is in: the handler is
        # registered, the configuration is not built yet.
        register_handler
      end

      # Registers this gem as the request handler for `PatientHttp`.
      #
      # The gem calls this method when it loads. As a result, the `PatientHttp`
      # module methods work in every process that loads the gem, whether or not
      # the process runs a processor. The handler stays registered for the life
      # of the process. After the processors stop, requests are enqueued in the
      # queue database for another process to run.
      #
      # @return [void]
      def register_handler
        @request_handler ||= lambda do |request:, callback:, raise_error_responses:, callback_args:|
          execute(
            request,
            callback: callback,
            raise_error_responses: raise_error_responses,
            callback_args: callback_args
          )
        end

        PatientHttp.register_handler(@request_handler)
      end

      # Calls the blocks registered with {after_completion}.
      #
      # @param response [PatientHttp::Response] The HTTP response.
      # @return [void]
      # @api private
      def invoke_completion_callbacks(response)
        @after_completion_callbacks.each do |callback|
          callback.call(response)
        rescue => e
          configuration.logger&.error("[PatientHttp::SolidQueue] after_completion callback error: #{e.class} - #{e.message}")
        end
      end

      # Calls the blocks registered with {after_error}.
      #
      # @param error [PatientHttp::Error] The error.
      # @return [void]
      # @api private
      def invoke_error_callbacks(error)
        @after_error_callbacks.each do |callback|
          callback.call(error)
        rescue => e
          configuration.logger&.error("[PatientHttp::SolidQueue] after_error callback error: #{e.class} - #{e.message}")
        end
      end

      # Encrypts data with the configured encryptor.
      #
      # @param value [Hash] The data to encrypt.
      # @return [Hash] The encrypted data, or the original data if encryption
      #   isn't configured.
      # @api private
      def encrypt(value)
        configuration.encryptor.encrypt(value)
      end

      # Decrypts data with the configured encryptor.
      #
      # @param value [Hash] The data to decrypt.
      # @return [Hash] The decrypted data, or the original data if it isn't
      #   encrypted.
      # @api private
      def decrypt(value)
        configuration.encryptor.decrypt(value)
      end

      # Returns the processor with the given name.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Processor, nil] The processor, or `nil` if no
      #   processor has that name.
      # @api private
      def processor(name = :default)
        @processors[name.to_sym]
      end

      # Sets the default processor. Intended for tests.
      #
      # @param value [PatientHttp::Processor, nil] The processor, or `nil` to
      #   remove it.
      # @return [void]
      # @api private
      def processor=(value)
        if value.nil?
          @processors.delete(:default)
        else
          @processors[:default] = value
        end
      end

      # Returns the configuration for a processor profile. Uses the running
      # processor's configuration if there is one. A name without a declared
      # profile uses the base configuration.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Configuration] The configuration for the profile.
      # @api private
      def processor_config_for(name)
        key = name.to_sym
        running = @processors[key]
        return running.config if running

        config = configuration
        config.processor_options(key) ? config.processor_config(key) : config
      end

      private

      # Stops every processor.
      #
      # Each processor waits up to the full timeout for its in-flight requests,
      # so the processors stop in parallel. Stopping them one at a time would
      # multiply the shutdown time by the number of processors. An error from
      # one processor is logged so that the other processors and the shared
      # services still shut down.
      #
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests.
      # @return [void]
      def stop_processors(timeout:)
        processors = @processors.values
        return if processors.empty?

        if processors.one?
          stop_processor(processors.first, timeout)
        else
          processors.map { |processor| Thread.new { stop_processor(processor, timeout) } }.each(&:join)
        end
      end

      # Stops a processor and logs any error instead of raising it.
      #
      # @param processor [PatientHttp::Processor] The processor.
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests.
      # @return [void]
      def stop_processor(processor, timeout)
        processor.stop(timeout: timeout)
      rescue => e
        configuration.logger&.error(
          "[PatientHttp::SolidQueue] Failed to stop processor #{processor.name}: #{e.inspect}"
        )
      end

      # Stops the monitor thread and removes this process from the registry. The
      # caller must hold the lifecycle mutex and must stop all processors first.
      #
      # @return [void]
      def shutdown_shared_services
        @monitor_thread&.stop
        @monitor_thread = nil
        begin
          @task_monitor&.remove_process
        rescue => e
          configuration.logger&.error("[PatientHttp::SolidQueue] Failed to remove process registration: #{e.inspect}")
        end
        @task_monitor = nil
      end
    end
  end
end

if defined?(::Rails::Engine)
  require_relative "solid_queue/engine"
end

# Wire the gem up as soon as it is loaded so that no setup step is required to
# start making requests:
#
# - the request handler is registered, so PatientHttp.get and friends work in
#   every process that requires the gem, configured or not;
# - PatientHttp.configure and PatientHttp.configuration resolve to this gem's
#   configuration, so applications never have to name the integration;
# - the Solid Queue lifecycle hooks start and stop the processor with the worker.
PatientHttp::SolidQueue.register_handler
PatientHttp.register_configuration_provider(PatientHttp::SolidQueue)
PatientHttp::SolidQueue::LifecycleHooks.register
