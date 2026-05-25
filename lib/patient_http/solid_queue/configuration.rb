# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Configuration for the Solid Queue Async HTTP gem.
    #
    # Wraps PatientHttp::Configuration with Solid Queue-aware defaults and adds
    # Solid Queue-specific options like queue name settings.
    class Configuration < PatientHttp::Configuration
      # Default threshold in bytes above which payloads are stored externally.
      DEFAULT_PAYLOAD_STORE_THRESHOLD = 64 * 1024 # 64KB

      # @return [Integer] Size threshold in bytes for external payload storage
      attr_reader :payload_store_threshold

      # @return [Numeric] Orphan detection threshold in seconds
      attr_reader :orphan_threshold

      # @return [Numeric] Heartbeat update interval in seconds
      attr_reader :heartbeat_interval

      # @return [String, nil] Queue name for RequestJob and CallbackJob
      attr_reader :queue_name

      # @return [#call, nil] Handler invoked when a CallbackWorker job exhausts all retries.
      # @overload on_retries_exhausted
      #   Returns the current handler.
      #   @return [#call, nil]
      # @overload on_retries_exhausted(&block)
      #   Sets a block as the handler.
      #   @yield [error] block to execute when retries are exhausted
      #   @yieldparam error [PatientHttp::Error] information about the error
      def on_retries_exhausted(&block)
        if block
          @on_retries_exhausted = block
        else
          @on_retries_exhausted
        end
      end

      # Buffer in seconds subtracted from SolidQueue.shutdown_timeout to derive
      # the default shutdown_timeout for this gem's connection pool.
      SHUTDOWN_TIMEOUT_BUFFER = 2

      # @param heartbeat_interval [Numeric] Interval in seconds for heartbeat updates (default: 60)
      # @param orphan_threshold [Numeric] Time in seconds to consider a job orphaned (default: 300)
      # @param queue_name [String, nil] Optional queue name for RequestJob and CallbackJob (default: nil)
      # @param payload_store_threshold [Integer] Size threshold in bytes for external payload storage (default: 64KB)
      # @param on_retries_exhausted [#call, nil] Handler called when a CallbackWorker job exhausts retries
      # @param pool_options [Hash] Additional options passed to the SolidQueue connection pool
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

        self.queue_name = queue_name
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.payload_store_threshold = payload_store_threshold || DEFAULT_PAYLOAD_STORE_THRESHOLD
        self.on_retries_exhausted = on_retries_exhausted
      end

      def payload_store_threshold=(value)
        validate_positive_integer(:payload_store_threshold, value)
        @payload_store_threshold = value
      end

      def heartbeat_interval=(value)
        raise ArgumentError, "heartbeat_interval must be positive, got: #{value.inspect}" unless value.positive?
        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      def orphan_threshold=(value)
        raise ArgumentError, "orphan_threshold must be positive, got: #{value.inspect}" unless value.positive?
        @orphan_threshold = value
        validate_heartbeat_and_threshold
      end

      def queue_name=(name)
        if name.nil?
          @queue_name = nil
          return
        end

        raise ArgumentError, "queue_name must be a String, got: #{name.class}" unless name.is_a?(String)
        @queue_name = name
        apply_queue_name(name)
      end

      # Set the on_retries_exhausted handler.
      #
      # This handler is called when a CallbackWorker job exhausts all retries.
      # It receives the same arguments as the on_error callback.
      #
      # @param value [#call, nil] A callable object or nil to clear the handler
      # @raise [ArgumentError] If value is not callable and not nil
      def on_retries_exhausted=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("on_retries_exhausted must respond to #call, got: #{value.class}")
        end

        @on_retries_exhausted = value
      end

      # @return [Hash] configuration as a hash for logging/inspection
      def to_h
        super.merge(
          "payload_store_threshold" => payload_store_threshold,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "queue_name" => queue_name,
          "on_retries_exhausted" => on_retries_exhausted ? "defined" : nil
        )
      end

      private

      def apply_queue_name(name)
        PatientHttp::SolidQueue::RequestJob.queue_as(name)
        PatientHttp::SolidQueue::CallbackJob.queue_as(name)
      end

      def validate_heartbeat_and_threshold
        return unless @heartbeat_interval && @orphan_threshold
        return unless @heartbeat_interval >= @orphan_threshold
        raise ArgumentError, "heartbeat_interval (#{@heartbeat_interval}) must be less than orphan_threshold (#{@orphan_threshold})"
      end
    end
  end
end
