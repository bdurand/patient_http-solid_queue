# frozen_string_literal: true

require "patient_http"
require "solid_queue"

module PatientHttp
  # Main module for the patient_http-solid_queue gem.
  #
  # The gem moves long-running HTTP requests out of Solid Queue jobs and into a
  # dedicated asynchronous I/O processor in the same process. Worker threads are
  # free to run other jobs while requests are in flight.
  #
  # == Usage
  #
  #   request = PatientHttp::Request.new(:get, "https://api.example.com/users/123")
  #   PatientHttp::SolidQueue.execute(
  #     request,
  #     callback: MyCallback,
  #     callback_args: {user_id: 123}
  #   )
  #
  # Define a callback service class with +on_complete+ and +on_error+ methods:
  #
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

    # Raised when the gem can't write the crash-recovery record for a request.
    # The processor rejects the request instead of accepting it without a
    # durable record, and the job retries.
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
    @configuration = nil
    @after_completion_callbacks = []
    @after_error_callbacks = []
    @external_storage = nil
    @request_handler = nil
    @lifecycle_mutex = Mutex.new
    @task_monitor = nil
    @monitor_thread = nil

    class << self
      attr_writer :configuration

      # Configures the gem with a block.
      #
      # The new configuration also becomes +PatientHttp.default_configuration+.
      # This applies secrets registered with +PatientHttp.register_secret+ to the
      # configuration that the processor uses, regardless of boot order.
      #
      # @yield [config] Block that sets configuration options.
      # @yieldparam config [Configuration] The new configuration.
      # @return [Configuration] The new configuration.
      def configure
        configuration = Configuration.new
        yield(configuration) if block_given?
        @configuration = configuration
        @external_storage = nil
        register_handler
        PatientHttp.default_configuration = configuration
        configuration
      end

      # Returns the current configuration. Creates a default configuration if
      # none is set.
      #
      # @return [Configuration] The current configuration.
      def configuration
        @configuration ||= Configuration.new
      end

      # Resets the configuration to the defaults. Use this in tests.
      #
      # @return [Configuration] The new default configuration.
      def reset_configuration!
        @configuration = nil
        @external_storage = nil
        configuration
      end

      # Registers a block to run after each HTTP request completes. The block
      # runs before the request's +on_complete+ callback.
      #
      # @yield [response] Block to run after a request completes.
      # @yieldparam response [PatientHttp::Response] The HTTP response.
      # @return [void]
      def after_completion(&block)
        @after_completion_callbacks << block
      end

      # Registers a block to run after each HTTP request error. The block runs
      # before the request's +on_error+ callback.
      #
      # @yield [error] Block to run after a request error.
      # @yieldparam error [PatientHttp::Error] Information about the error.
      # @return [void]
      def after_error(&block)
        @after_error_callbacks << block
      end

      # Returns whether any processor is running.
      #
      # @return [Boolean] +true+ if any processor is running; otherwise, +false+.
      def running?
        @processors.values.any?(&:running?)
      end

      # Returns whether any processor is draining. A draining processor doesn't
      # accept new requests.
      #
      # @return [Boolean] +true+ if any processor is draining; otherwise, +false+.
      def draining?
        @processors.values.any?(&:draining?)
      end

      # Returns whether any processor is stopping.
      #
      # @return [Boolean] +true+ if any processor is stopping; otherwise, +false+.
      def stopping?
        @processors.values.any?(&:stopping?)
      end

      # Returns whether all processors are stopped. Also returns +true+ if no
      # processor has started.
      #
      # @return [Boolean] +true+ if no processor is active; otherwise, +false+.
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

      # Enqueues an HTTP request to run asynchronously.
      #
      # @param request [PatientHttp::Request] The HTTP request to run.
      # @param callback [Class, String] The callback service class, or its fully
      #   qualified class name. The class must define +on_complete+ and +on_error+
      #   instance methods.
      # @param callback_args [#to_h, nil] Arguments to pass to the callback.
      # @param raise_error_responses [Boolean] If +true+, the gem treats non-2xx
      #   responses as errors.
      # @param processor [Symbol, String, nil] The name of the processor profile
      #   that runs the request. Defaults to the request's processor name, or
      #   +:default+ if the request doesn't set one.
      # @return [String] The request ID.
      # @raise [PatientHttp::UnknownProcessorError] If the processor profile isn't
      #   configured.
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

      # Starts a processor for each configured processor profile, and starts the
      # shared crash-recovery monitor.
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

      # Signals all processors to drain. Draining processors stop accepting new
      # requests.
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
      # The request handler stays registered. Solid Queue runs its worker stop
      # hooks before it drains the execution pool. If a job submits a request
      # after the processors stop, the handler enqueues the request as a job for
      # the next process instead of raising an error. Only {.reset!} removes the
      # handler.
      #
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests to finish.
      # @return [void]
      def stop(timeout: nil)
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
        if @request_handler
          PatientHttp.unregister_handler(@request_handler)
        end
        @lifecycle_mutex.synchronize do
          stop_processors(timeout: 0)
          @processors = {}
          shutdown_shared_services
        end
        @configuration = nil
        @external_storage = nil
        @after_completion_callbacks = []
        @after_error_callbacks = []
      end

      # Registers this gem as the handler for +PatientHttp+ requests. The gem calls
      # this method when the processor starts and when you call {.configure}.
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

      # Runs the registered completion callbacks.
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

      # Runs the registered error callbacks.
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
      # @param value [String] The encrypted value.
      # @return [Object] The decrypted value.
      def decrypt(value)
        configuration.encryptor.decrypt(value)
      end

      # Returns a running processor by name.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Processor, nil] The processor, or +nil+ if no
      #   processor with that name is running.
      # @api private
      def processor(name = :default)
        @processors[name.to_sym]
      end

      # Sets the default processor. Use this in tests.
      #
      # @param value [PatientHttp::Processor, nil] The processor, or +nil+ to
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
      # timeout limits the whole shutdown instead of each processor in turn.
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
      # registry. Call this with the lifecycle mutex held, after all processors
      # stop.
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

PatientHttp::SolidQueue::LifecycleHooks.register
