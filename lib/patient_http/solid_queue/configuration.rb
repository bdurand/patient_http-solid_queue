# frozen_string_literal: true

require "delegate"

module PatientHttp
  module SolidQueue
    # Configuration for the patient_http-solid_queue gem.
    #
    # Extends +PatientHttp::Configuration+ with defaults for Solid Queue and adds
    # Solid Queue options, such as the queue name and crash-recovery settings.
    class Configuration < PatientHttp::Configuration
      # Default threshold in bytes above which payloads are stored externally.
      DEFAULT_PAYLOAD_STORE_THRESHOLD = 64 * 1024 # 64KB

      # @return [Integer] The size in bytes above which payloads go to external
      #   storage.
      attr_reader :payload_store_threshold

      # @return [Numeric] The number of seconds without a heartbeat after which a
      #   request counts as orphaned.
      attr_reader :orphan_threshold

      # @return [Numeric] The number of seconds between heartbeat updates.
      attr_reader :heartbeat_interval

      # @return [String, nil] The queue name for +RequestJob+ and +CallbackJob+.
      attr_reader :queue_name

      # Gets or sets the handler that runs when an error callback job exhausts
      # its retries.
      #
      # @overload on_retries_exhausted
      #   Returns the current handler.
      #   @return [#call, nil] The handler, or +nil+ if none is set.
      # @overload on_retries_exhausted(&block)
      #   Sets a block as the handler.
      #   @yield [error] Block to run when retries are exhausted.
      #   @yieldparam error [PatientHttp::Error] Information about the error.
      #   @return [Proc] The block.
      def on_retries_exhausted(&block)
        if block
          @on_retries_exhausted = block
        else
          @on_retries_exhausted
        end
      end

      # Seconds subtracted from +SolidQueue.shutdown_timeout+ to get the default
      # +shutdown_timeout+ for this gem's connection pool.
      SHUTDOWN_TIMEOUT_BUFFER = 2

      # Creates a configuration.
      #
      # @param heartbeat_interval [Numeric] The number of seconds between heartbeat
      #   updates. Defaults to 60.
      # @param orphan_threshold [Numeric] The number of seconds without a heartbeat
      #   after which a request counts as orphaned. Defaults to 300.
      # @param queue_name [String, nil] The queue name for +RequestJob+ and
      #   +CallbackJob+. Defaults to +nil+, which uses the Active Job default.
      # @param payload_store_threshold [Integer] The size in bytes above which
      #   payloads go to external storage. Defaults to 64 KB.
      # @param on_retries_exhausted [#call, nil] The handler that runs when an
      #   error callback job exhausts its retries.
      # @param pool_options [Hash] Other options for +PatientHttp::Configuration+.
      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        queue_name: nil,
        payload_store_threshold: DEFAULT_PAYLOAD_STORE_THRESHOLD,
        on_retries_exhausted: nil,
        **pool_options
      )
        if ::SolidQueue.shutdown_timeout
          pool_options[:shutdown_timeout] ||= [::SolidQueue.shutdown_timeout - SHUTDOWN_TIMEOUT_BUFFER, 1].max
        end
        pool_options[:user_agent] ||= "SolidQueue-AsyncHttp"
        pool_options[:logger] ||= (defined?(SolidQueue.logger) ? SolidQueue.logger : nil)

        super(**pool_options)

        @processor_profiles = {default: {}}
        self.queue_name = queue_name
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.payload_store_threshold = payload_store_threshold || DEFAULT_PAYLOAD_STORE_THRESHOLD
        self.on_retries_exhausted = on_retries_exhausted
      end

      # Declares a named processor profile.
      #
      # Each profile runs as a separate processor with its own capacity,
      # timeouts, and threads. The options override this configuration's HTTP
      # pool options. A profile with no options inherits every option. To select
      # a processor, pass the +processor:+ option to
      # +PatientHttp::SolidQueue.execute+ or set it on the request. The
      # +:default+ profile always exists. Declare it to override the options of
      # the default processor.
      #
      # @example
      #   PatientHttp::SolidQueue.configure do |config|
      #     config.processor(:llm, max_connections: 200, request_timeout: 120)
      #     config.processor(:webhooks, max_connections: 64, request_timeout: 10)
      #   end
      #
      # @param name [Symbol, String] The processor name.
      # @param options [Hash] Overrides for +PatientHttp::Configuration+ options.
      # @return [Hash] The stored options for the profile.
      # @raise [ArgumentError] If the name is empty or an option is invalid.
      def processor(name, **options)
        key = normalize_processor_name(name)
        @processor_profiles[key] = normalize_profile_options!(options)
      end

      # Returns the options declared for a named processor profile.
      #
      # @param name [Symbol, String] The processor name.
      # @return [Hash, nil] The stored options, or +nil+ if the profile isn't
      #   declared.
      def processor_options(name)
        @processor_profiles[normalize_processor_name(name)]
      end

      # Returns all declared processor profiles. The result always includes
      # +:default+.
      #
      # @return [Hash{Symbol => Hash}] The profile options, keyed by processor name.
      def processor_profiles
        @processor_profiles.dup
      end

      # Returns the effective configuration for a named processor.
      #
      # A profile with no overrides uses this configuration. Other profiles get
      # a view of this configuration with their overrides applied, so all
      # profiles share secrets, preprocessors, payload stores, and encryption.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Configuration] The configuration for the processor.
      # @raise [ArgumentError] If the profile isn't declared.
      def processor_config(name)
        key = normalize_processor_name(name)
        profile = @processor_profiles[key]
        raise ArgumentError.new("Unknown processor profile: #{name.inspect}") unless profile

        return self if profile.empty?

        ProfileConfiguration.new(self, profile)
      end

      # Sets the size above which payloads go to external storage.
      #
      # @param value [Integer] The size in bytes.
      # @raise [ArgumentError] If the value isn't a positive integer.
      def payload_store_threshold=(value)
        validate_positive_integer(:payload_store_threshold, value)
        @payload_store_threshold = value
      end

      # Sets the number of seconds between heartbeat updates.
      #
      # @param value [Numeric] The interval in seconds.
      # @raise [ArgumentError] If the value isn't positive or isn't less than
      #   {#orphan_threshold}.
      def heartbeat_interval=(value)
        raise ArgumentError, "heartbeat_interval must be positive, got: #{value.inspect}" unless value.positive?
        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      # Sets the number of seconds without a heartbeat after which a request
      # counts as orphaned.
      #
      # @param value [Numeric] The threshold in seconds.
      # @raise [ArgumentError] If the value isn't positive or isn't greater than
      #   {#heartbeat_interval}.
      def orphan_threshold=(value)
        raise ArgumentError, "orphan_threshold must be positive, got: #{value.inspect}" unless value.positive?
        @orphan_threshold = value
        validate_heartbeat_and_threshold
      end

      # Sets the queue name for +RequestJob+ and +CallbackJob+.
      #
      # @param name [String, nil] The queue name, or +nil+ to use the Active Job
      #   default.
      # @raise [ArgumentError] If the name isn't a string or +nil+.
      def queue_name=(name)
        if name.nil?
          @queue_name = nil
          return
        end

        raise ArgumentError, "queue_name must be a String, got: #{name.class}" unless name.is_a?(String)
        @queue_name = name
        apply_queue_name(name)
      end

      # Sets the handler that runs when an error callback job exhausts its
      # retries. The handler receives the same argument as the +on_error+
      # callback.
      #
      # @param value [#call, nil] A callable object, or +nil+ to clear the handler.
      # @raise [ArgumentError] If the value isn't callable or +nil+.
      def on_retries_exhausted=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("on_retries_exhausted must respond to #call, got: #{value.class}")
        end

        @on_retries_exhausted = value
      end

      # Returns the configuration as a hash for logging and inspection.
      #
      # @return [Hash] The configuration values.
      def to_h
        super.merge(
          "payload_store_threshold" => payload_store_threshold,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "queue_name" => queue_name,
          "on_retries_exhausted" => on_retries_exhausted ? "defined" : nil,
          "processor_profiles" => processor_profiles.keys.map(&:to_s)
        )
      end

      # View of a base configuration with a profile's option overrides applied.
      # Settings that the profile doesn't override delegate to the base
      # configuration. These include secrets, preprocessors, payload stores,
      # encryption, and logging, so all processors share them.
      class ProfileConfiguration < SimpleDelegator
        # Creates a profile view of a configuration.
        #
        # @param base_configuration [PatientHttp::Configuration] The configuration
        #   to delegate to.
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

      # Validates and normalizes profile options. Each option must be a valid
      # +PatientHttp::Configuration+ option. A throwaway configuration runs each
      # option's validation and normalization, so the stored value matches what
      # the option's writer produces instead of the raw input.
      def normalize_profile_options!(options)
        return options if options.empty?

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
