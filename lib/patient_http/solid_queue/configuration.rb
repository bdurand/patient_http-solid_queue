# frozen_string_literal: true

require "delegate"

module PatientHttp
  module SolidQueue
    # Configuration for the Solid Queue integration.
    #
    # Extends `PatientHttp::Configuration` with Solid Queue defaults and adds
    # options for the job queue, crash recovery, and named processor profiles.
    class Configuration < PatientHttp::Configuration
      # Default size in bytes above which payloads are stored externally.
      #
      # @deprecated Use {PatientHttp::Configuration::DEFAULT_PAYLOAD_STORE_THRESHOLD}.
      #   The `payload_store_threshold` option is defined on the base
      #   configuration, next to `register_payload_store`.
      DEFAULT_PAYLOAD_STORE_THRESHOLD = PatientHttp::Configuration::DEFAULT_PAYLOAD_STORE_THRESHOLD

      # @return [Numeric] The number of seconds without a heartbeat after which
      #   an in-flight request is considered orphaned and re-enqueued.
      attr_reader :orphan_threshold

      # @return [Numeric] The number of seconds between heartbeat updates for
      #   in-flight requests.
      attr_reader :heartbeat_interval

      # @return [String, nil] The queue name for `RequestJob` and `CallbackJob`.
      attr_reader :queue_name

      # Returns or sets the handler that runs when Active Job discards a
      # `CallbackJob`.
      #
      # @overload on_retries_exhausted
      #   Returns the current handler.
      #   @return [#call, nil] The handler, or `nil` if none is set.
      # @overload on_retries_exhausted(&block)
      #   Sets a block as the handler.
      #   @yield [error] The block to run when a job is discarded.
      #   @yieldparam error [PatientHttp::Error] The error from the request.
      def on_retries_exhausted(&block)
        if block
          @on_retries_exhausted = block
        else
          @on_retries_exhausted
        end
      end

      # Seconds subtracted from `SolidQueue.shutdown_timeout` to get the default
      # `shutdown_timeout` for this gem's processor.
      SHUTDOWN_TIMEOUT_BUFFER = 2

      # Creates a configuration.
      #
      # @param heartbeat_interval [Numeric] The number of seconds between
      #   heartbeat updates for in-flight requests.
      # @param orphan_threshold [Numeric] The number of seconds without a
      #   heartbeat after which an in-flight request is considered orphaned.
      # @param queue_name [String, nil] The queue name for `RequestJob` and
      #   `CallbackJob`. If `nil`, the Active Job default queue applies.
      # @param on_retries_exhausted [#call, nil] The handler that runs when
      #   Active Job discards a `CallbackJob`.
      # @param pool_options [Hash] Options for `PatientHttp::Configuration`. If
      #   `shutdown_timeout` isn't set, it defaults to the Solid Queue shutdown
      #   timeout minus 2 seconds. If `logger` isn't set, it defaults to the
      #   Solid Queue logger.
      # @raise [ArgumentError] If an option isn't valid.
      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        queue_name: nil,
        on_retries_exhausted: nil,
        **pool_options
      )
        # The Solid Queue defaults for these options are read when the options
        # are used, so settings that Solid Queue gets after this configuration
        # is built still apply.
        pool_options = pool_options.compact

        super(**pool_options)

        @shutdown_timeout_set = pool_options.key?(:shutdown_timeout)
        @logger_set = pool_options.key?(:logger)
        @processor_profiles = {default: {}}
        @profile_configs = {}
        @profile_configs_mutex = Mutex.new
        self.queue_name = queue_name
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.on_retries_exhausted = on_retries_exhausted
      end

      # Declares a named processor profile.
      #
      # Each profile becomes an independent processor with its own capacity,
      # timeouts, and threads. The options override this configuration's HTTP
      # options. With no options, the profile inherits every option. A request
      # selects a processor with the `processor:` option, or with the
      # request's own processor name. The `:default` profile always exists.
      # Declare it to override options for the default processor.
      #
      # @example
      #   PatientHttp.configure do |config|
      #     config.processor(:llm, max_connections: 200, request_timeout: 120)
      #     config.processor(:webhooks, max_connections: 64, request_timeout: 10)
      #   end
      #
      # @param name [Symbol, String] The processor name.
      # @param options [Hash] Overrides for `PatientHttp::Configuration`
      #   options. `encryption_key` can't be overridden, because all processors
      #   share encryption.
      # @return [Hash] The stored options for the profile.
      # @raise [ArgumentError] If the name is empty or an option is invalid.
      def processor(name, **options)
        key = normalize_processor_name(name)
        normalized = normalize_profile_options!(options)
        @profile_configs_mutex.synchronize do
          @profile_configs.delete(key)
          @processor_profiles[key] = normalized
        end
      end

      # Returns the options declared for a named processor profile.
      #
      # @param name [Symbol, String] The processor name.
      # @return [Hash, nil] The stored options, or `nil` if the profile isn't
      #   declared.
      def processor_options(name)
        key = name.to_s
        return nil if key.empty?

        @processor_profiles[key.to_sym]
      end

      # Returns all declared processor profiles, including `:default`.
      #
      # @return [Hash{Symbol => Hash}] The profile options, keyed by processor
      #   name.
      def processor_profiles
        @processor_profiles.dup
      end

      # Returns the configuration for a named processor.
      #
      # A profile without overrides uses this configuration. Other profiles use
      # a view of this configuration with their overrides applied, so all
      # processors share secrets, preprocessors, payload stores, and
      # encryption. The view is built once and reused until the profile is
      # declared again.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Configuration] The configuration for the processor.
      # @raise [ArgumentError] If the profile isn't declared.
      def processor_config(name)
        key = normalize_processor_name(name)

        @profile_configs_mutex.synchronize do
          profile = @processor_profiles[key]
          raise ArgumentError.new("Unknown processor profile: #{name.inspect}") unless profile

          return self if profile.empty?

          @profile_configs[key] ||= ProfileConfiguration.new(self, profile)
        end
      end

      # Returns the graceful shutdown timeout in seconds. If it isn't set,
      # returns the Solid Queue shutdown timeout minus 2 seconds, so that the
      # processor stops before Solid Queue gives up on the worker.
      #
      # @return [Numeric] The timeout in seconds.
      def shutdown_timeout
        solid_queue_timeout = ::SolidQueue.shutdown_timeout
        return super if @shutdown_timeout_set || solid_queue_timeout.nil?

        [solid_queue_timeout - SHUTDOWN_TIMEOUT_BUFFER, 1].max
      end

      # Sets the graceful shutdown timeout in seconds.
      #
      # @param value [Numeric] The timeout in seconds. Must be positive.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't positive.
      def shutdown_timeout=(value)
        super
        @shutdown_timeout_set = true
      end

      # Returns the logger. If it isn't set, returns the Solid Queue logger.
      #
      # @return [Logger] The logger.
      def logger
        return super if @logger_set

        solid_queue_logger = ::SolidQueue.logger if ::SolidQueue.respond_to?(:logger)
        solid_queue_logger || super
      end

      # Sets the logger.
      #
      # @param value [Logger, nil] The logger.
      # @return [void]
      def logger=(value)
        super
        @logger_set = true
      end

      # Sets the number of seconds between heartbeat updates for in-flight
      # requests.
      #
      # @param value [Numeric] The interval in seconds. Must be positive and less
      #   than `orphan_threshold`.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't positive or isn't less than
      #   `orphan_threshold`.
      def heartbeat_interval=(value)
        raise ArgumentError, "heartbeat_interval must be positive, got: #{value.inspect}" unless value.positive?
        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      # Sets the number of seconds without a heartbeat after which an in-flight
      # request is considered orphaned and re-enqueued.
      #
      # @param value [Numeric] The threshold in seconds. Must be positive and
      #   greater than `heartbeat_interval`.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't positive or isn't greater than
      #   `heartbeat_interval`.
      def orphan_threshold=(value)
        raise ArgumentError, "orphan_threshold must be positive, got: #{value.inspect}" unless value.positive?
        @orphan_threshold = value
        validate_heartbeat_and_threshold
      end

      # Sets the queue name for `RequestJob` and `CallbackJob`.
      #
      # @param name [String, nil] The queue name, or `nil` to use the Active Job
      #   default queue.
      # @return [void]
      # @raise [ArgumentError] If `name` isn't `nil` or a String.
      def queue_name=(name)
        if name.nil?
          @queue_name = nil
          return
        end

        raise ArgumentError, "queue_name must be a String, got: #{name.class}" unless name.is_a?(String)
        @queue_name = name
        apply_queue_name(name)
      end

      # Sets the handler that runs when Active Job discards a `CallbackJob`. The
      # handler receives the same error object as the `on_error` callback.
      #
      # @param value [#call, nil] A callable object, or `nil` to remove the
      #   handler.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't `nil` and doesn't respond to
      #   `call`.
      def on_retries_exhausted=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("on_retries_exhausted must respond to #call, got: #{value.class}")
        end

        @on_retries_exhausted = value
      end

      # Returns the configuration as a Hash for inspection.
      #
      # @return [Hash{String => Object}] The option values, keyed by option
      #   name.
      def to_h
        super.merge(
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "queue_name" => queue_name,
          "on_retries_exhausted" => on_retries_exhausted ? "defined" : nil,
          "processor_profiles" => processor_profiles.keys.map(&:to_s)
        )
      end

      # A view of a base configuration with a processor profile's overrides
      # applied. Options that the profile doesn't override, such as secrets,
      # preprocessors, payload stores, and the logger, come from the base
      # configuration, so all processors share them.
      class ProfileConfiguration < SimpleDelegator
        # Creates a view of the base configuration.
        #
        # @param base_configuration [PatientHttp::Configuration] The
        #   configuration to delegate to.
        # @param overrides [Hash] Option values that replace the base values.
        def initialize(base_configuration, overrides)
          super(base_configuration)
          overrides.each do |key, value|
            define_singleton_method(key) { value }
          end
        end
      end

      private

      def apply_queue_name(name)
        PatientHttp::SolidQueue::RequestJob.queue_as(name)
        PatientHttp::SolidQueue::CallbackJob.queue_as(name)
      end

      # Profile options must be valid PatientHttp::Configuration options other
      # than `encryption_key`, which all processors share. A
      # throwaway configuration exercises each option's own validation and
      # normalization, so the stored value is what the writer would have
      # produced rather than the raw input.
      def normalize_profile_options!(options)
        return options if options.empty?

        if options.key?(:encryption_key)
          raise ArgumentError.new("encryption_key can't be set for a processor profile")
        end

        probe = PatientHttp::Configuration.new(**options)
        options.to_h do |key, value|
          [key, probe.respond_to?(key) ? probe.public_send(key) : value]
        end
      rescue ArgumentError => e
        raise ArgumentError.new("Invalid processor profile options: #{e.message}")
      end

      def normalize_processor_name(name)
        key = name.to_s
        raise ArgumentError.new("processor name cannot be empty") if key.empty?

        key.to_sym
      end

      def validate_heartbeat_and_threshold
        return unless @heartbeat_interval && @orphan_threshold
        return unless @heartbeat_interval >= @orphan_threshold
        raise ArgumentError, "heartbeat_interval (#{@heartbeat_interval}) must be less than orphan_threshold (#{@orphan_threshold})"
      end
    end
  end
end
