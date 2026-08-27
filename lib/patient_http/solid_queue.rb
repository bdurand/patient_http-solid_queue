# frozen_string_literal: true

require "patient_http"
require "solid_queue"

# Main module for the Solid Queue Async HTTP gem.
#
# This gem provides a mechanism to offload long-running HTTP requests from Solid Queue workers
# to a dedicated async I/O processor running in the same process, freeing worker threads
# immediately while HTTP requests are in flight.
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
module PatientHttp
  module SolidQueue
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

    # Raised when the crash-recovery registry entry for a request cannot be
    # written. The request is rejected rather than accepted without a durable
    # record, and the job retries.
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

      # Configure the gem with a block. The built configuration is also set as the
      # `PatientHttp.default_configuration` so that secrets registered at the module
      # level with `PatientHttp.register_secret` are applied to the configuration the
      # processor runs with, regardless of boot order.
      #
      # @yield [Configuration] the configuration object
      # @return [Configuration]
      def configure
        configuration = Configuration.new
        yield(configuration) if block_given?
        @configuration = configuration
        @external_storage = nil
        register_handler
        PatientHttp.default_configuration = configuration
        configuration
      end

      # Return the current configuration, initializing with defaults if necessary.
      #
      # @return [Configuration]
      def configuration
        @configuration ||= Configuration.new
      end

      # Reset configuration to defaults (useful for testing).
      #
      # @return [Configuration]
      def reset_configuration!
        @configuration = nil
        @external_storage = nil
        configuration
      end

      # Add a callback to be executed after a successful request completion.
      #
      # @yield [response] block to execute after an HTTP request completes
      # @yieldparam response [PatientHttp::Response] the HTTP response
      def after_completion(&block)
        @after_completion_callbacks << block
      end

      # Add a callback to be executed after a request error.
      #
      # @yield [error] block to execute after an HTTP request errors
      # @yieldparam error [PatientHttp::Error] information about the error
      def after_error(&block)
        @after_error_callbacks << block
      end

      # Check if any processor is running.
      #
      # @return [Boolean]
      def running?
        @processors.values.any?(&:running?)
      end

      # Check if any processor is draining (not accepting new requests).
      #
      # @return [Boolean]
      def draining?
        @processors.values.any?(&:draining?)
      end

      # Check if any processor is stopping.
      #
      # @return [Boolean]
      def stopping?
        @processors.values.any?(&:stopping?)
      end

      # Check if all processors are stopped or none have been started.
      #
      # @return [Boolean]
      def stopped?
        @processors.values.all?(&:stopped?)
      end

      # Get an ExternalStorage instance for storing and fetching payloads.
      #
      # @return [PatientHttp::ExternalStorage]
      # @api private
      def external_storage
        @external_storage ||= PatientHttp::ExternalStorage.new(configuration)
      end

      # Execute an async HTTP request.
      #
      # @param request [PatientHttp::Request] the HTTP request to execute
      # @param callback [Class, String] Callback service class with +on_complete+ and +on_error+
      #   instance methods, or its fully qualified class name.
      # @param callback_args [#to_h, nil] Arguments to pass to callback
      # @param raise_error_responses [Boolean] If true, treats non-2xx responses as errors
      # @param processor [Symbol, String, nil] Name of the processor profile that should
      #   execute the request. Defaults to the request's own processor name or :default.
      # @return [String] the request ID
      # @raise [PatientHttp::UnknownProcessorError] if the processor profile is not configured
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

      # Start a processor for each configured processor profile, along with
      # the shared crash-recovery monitor.
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

      # Signal all processors to drain (stop accepting new requests).
      #
      # @return [void]
      def quiet
        @lifecycle_mutex.synchronize do
          return unless running?

          @processors.each_value(&:drain)
        end
      end

      # Stop all processors gracefully.
      #
      # @param timeout [Float, nil] maximum time to wait for in-flight requests to complete
      # @return [void]
      def stop(timeout: nil)
        if @request_handler
          PatientHttp.unregister_handler(@request_handler)
        end

        @lifecycle_mutex.synchronize do
          return if @processors.empty?

          stop_processors(timeout: timeout)
          @processors = {}
          shutdown_shared_services
        end
      end

      # Reset all state (useful for testing).
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

      # Register SolidQueue as the request handler for processing HTTP requests. This is called
      # automatically when the processor starts or you call PatientHttp::SolidQueue.configure.
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

      # Invoke the registered completion callbacks.
      #
      # @param response [PatientHttp::Response] the HTTP response
      # @return [void]
      # @api private
      def invoke_completion_callbacks(response)
        @after_completion_callbacks.each do |callback|
          callback.call(response)
        rescue => e
          configuration.logger&.error("[PatientHttp::SolidQueue] after_completion callback error: #{e.class} - #{e.message}")
        end
      end

      # Invoke the registered error callbacks.
      #
      # @param error [PatientHttp::Error] information about the error
      # @return [void]
      # @api private
      def invoke_error_callbacks(error)
        @after_error_callbacks.each do |callback|
          callback.call(error)
        rescue => e
          configuration.logger&.error("[PatientHttp::SolidQueue] after_error callback error: #{e.class} - #{e.message}")
        end
      end

      # Encrypt a value using the configured encryptor.
      #
      # @param value [Object] the value to encrypt
      # @return [String] the encrypted value
      def encrypt(value)
        configuration.encryptor.encrypt(value)
      end

      # Decrypt a value using the configured encryptor.
      #
      # @param value [String] the encrypted value to decrypt
      # @return [Object] the decrypted value
      def decrypt(value)
        configuration.encryptor.decrypt(value)
      end

      # Returns a processor instance by name (internal accessor).
      #
      # @param name [Symbol, String] the processor name
      # @return [PatientHttp::Processor, nil]
      # @api private
      def processor(name = :default)
        @processors[name.to_sym]
      end

      # Set the default processor (internal, for testing).
      #
      # @param value [PatientHttp::Processor, nil]
      # @api private
      def processor=(value)
        if value.nil?
          @processors.delete(:default)
        else
          @processors[:default] = value
        end
      end

      private

      # Stop every processor, draining them at the same time so the timeout
      # bounds the whole shutdown instead of each processor in turn.
      def stop_processors(timeout:)
        processors = @processors.values
        return if processors.empty?

        if processors.one?
          processors.first.stop(timeout: timeout)
        else
          processors.map { |processor| Thread.new { processor.stop(timeout: timeout) } }.each(&:join)
        end
      end

      # Stop the shared monitor thread and remove this process from the
      # registry. Called with the lifecycle mutex held after all processors
      # have stopped.
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
