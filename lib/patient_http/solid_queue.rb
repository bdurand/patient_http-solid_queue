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
      # Replaces the configuration. Use this in tests.
      #
      # `PatientHttp` stores the configuration, so this method assigns it there.
      #
      # @param config [Configuration, nil] The configuration to use.
      # @return [void]
      def configuration=(config)
        PatientHttp.default_configuration = config
      end

      # Configures the gem with a block.
      #
      # Each call yields the same configuration object, so options accumulate.
      # Several initializers can each set options without overwriting one
      # another. `PatientHttp.configure` delegates to this method, so
      # application code can use either one.
      #
      # @example
      #   PatientHttp.configure do |config|
      #     config.max_connections = 512
      #   end
      #
      # @yield [config] Sets options on the configuration.
      # @yieldparam config [Configuration] The configuration object.
      # @return [Configuration] The configuration object.
      def configure
        config = configuration
        yield(config) if block_given?
        @external_storage = nil
        config
      end

      # Returns the configuration for this process and creates it on first use.
      #
      # `PatientHttp` stores the configuration object, so this method and
      # `PatientHttp.configuration` return the same object. Secrets that
      # `PatientHttp.register_secret` registers at the module level therefore
      # reach the processor's configuration, regardless of boot order.
      #
      # @return [Configuration] The configuration object.
      def configuration
        PatientHttp.configuration
      end

      # Builds a new configuration instance. `PatientHttp` calls this method
      # when it creates the configuration for this process.
      #
      # @return [Configuration] A new configuration object.
      # @api private
      def new_configuration
        Configuration.new
      end

      # Resets the configuration to its defaults. Use this in tests.
      #
      # @return [Configuration] The new configuration object.
      def reset_configuration!
        @external_storage = nil
        PatientHttp.default_configuration = nil
        configuration
      end

      # Adds a callback that runs after a request completes. Callbacks run in
      # the order that they're added.
      #
      # @yield [response] Runs after an HTTP request completes.
      # @yieldparam response [PatientHttp::Response] The HTTP response.
      # @return [void]
      def after_completion(&block)
        @after_completion_callbacks << block
      end

      # Adds a callback that runs after a request fails. Callbacks run in the
      # order that they're added.
      #
      # @yield [error] Runs after an HTTP request fails.
      # @yieldparam error [PatientHttp::Error] Information about the error.
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

      # Returns whether any processor is draining. A draining processor
      # doesn't accept new requests.
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
      # @return [Boolean] `true` if all processors are stopped or none have
      #   started.
      def stopped?
        @processors.values.all?(&:stopped?)
      end

      # Returns the external storage that stores and fetches payloads.
      #
      # @return [PatientHttp::ExternalStorage] The external storage.
      # @api private
      def external_storage
        @external_storage ||= PatientHttp::ExternalStorage.new(configuration)
      end

      # Enqueues an async HTTP request.
      #
      # In application code, use the `PatientHttp` module methods instead,
      # such as `PatientHttp.get`, `PatientHttp.post`, `PatientHttp.request`,
      # or the `PatientHttp::RequestHelper` mixin. Those methods take the same
      # options, including `processor:`, and keep application code free of
      # references to the job system. Use this method to dispatch a request
      # object that's already built.
      #
      # @param request [PatientHttp::Request] The HTTP request to execute.
      # @param callback [Class, String] The callback service class, or its fully
      #   qualified class name. The class must define `on_complete` and
      #   `on_error` instance methods.
      # @param callback_args [#to_h, nil] Arguments to pass to the callback.
      # @param raise_error_responses [Boolean] If `true`, treats non-2xx
      #   responses as errors.
      # @param processor [Symbol, String, nil] The name of the processor profile
      #   that runs the request. Defaults to the request's processor name, or
      #   `:default`.
      # @return [String] The request ID.
      # @raise [PatientHttp::UnknownProcessorError] If the processor profile
      #   isn't configured.
      def execute(request, callback:, callback_args: nil, raise_error_responses: false, processor: nil)
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

        encrypted = encrypt(request.as_json)

        data = if external_storage.enabled?
          external_storage.store(encrypted, max_size: configuration.payload_store_threshold)
        else
          encrypted
        end

        RequestJob.perform_later(data, callback_name, raise_error_responses, callback_args, request_id, processor_name)

        request_id
      end

      # Starts a processor for each configured processor profile, and the
      # shared crash recovery monitor.
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

      # Signals all processors to drain. A draining processor stops accepting
      # new requests.
      #
      # @return [void]
      def quiet
        @lifecycle_mutex.synchronize do
          return unless running?

          @processors.each_value(&:drain)
        end
      end

      # Stops all processors gracefully.
      #
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests to complete.
      # @return [void]
      def stop(timeout: nil)
        # The request handler stays registered. A request made while the process
        # is shutting down is enqueued and run by another process, which is
        # better than raising because no handler is registered.
        @lifecycle_mutex.synchronize do
          return if @processors.empty?

          stop_processors(timeout: timeout)
          @processors = {}
          shutdown_shared_services
        end
      end

      # Resets all state. Use this in tests.
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

      # Registers Solid Queue as the handler for HTTP requests.
      #
      # The gem calls this method when it loads, so requests made through the
      # `PatientHttp` module work in every process that requires the gem. This
      # is true whether or not the application configures the gem or runs a
      # worker. The handler stays registered for the life of the process. After
      # the processor stops, requests are enqueued for another process to run.
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

      # Calls the registered completion callbacks.
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

      # Calls the registered error callbacks.
      #
      # @param error [PatientHttp::Error] Information about the error.
      # @return [void]
      # @api private
      def invoke_error_callbacks(error)
        @after_error_callbacks.each do |callback|
          callback.call(error)
        rescue => e
          configuration.logger&.error("[PatientHttp::SolidQueue] after_error callback error: #{e.class} - #{e.message}")
        end
      end

      # Encrypts a value with the configured encryptor.
      #
      # @param value [Object] The value to encrypt.
      # @return [String] The encrypted value.
      def encrypt(value)
        configuration.encryptor.encrypt(value)
      end

      # Decrypts a value with the configured encryptor.
      #
      # @param value [String] The encrypted value to decrypt.
      # @return [Object] The decrypted value.
      def decrypt(value)
        configuration.encryptor.decrypt(value)
      end

      # Returns a processor by name.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Processor, nil] The processor, or `nil` if no
      #   processor with that name is running.
      # @api private
      def processor(name = :default)
        @processors[name.to_sym]
      end

      # Sets the default processor. Use this in tests.
      #
      # @param value [PatientHttp::Processor, nil] The processor, or `nil` to
      #   remove the default processor.
      # @api private
      def processor=(value)
        if value.nil?
          @processors.delete(:default)
        else
          @processors[:default] = value
        end
      end

      private

      # Stops every processor. The processors drain at the same time, so the
      # timeout bounds the whole shutdown instead of each processor in turn.
      def stop_processors(timeout:)
        processors = @processors.values
        return if processors.empty?

        if processors.one?
          processors.first.stop(timeout: timeout)
        else
          processors.map { |processor| Thread.new { processor.stop(timeout: timeout) } }.each(&:join)
        end
      end

      # Stops the shared monitor thread and removes this process from the
      # registry. Callers must hold the lifecycle mutex, and all processors
      # must be stopped.
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
