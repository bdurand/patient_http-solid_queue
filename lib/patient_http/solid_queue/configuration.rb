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

      # @return [#call] The configured encryptor callable
      attr_reader :encryptor

      # @return [#call] The configured decryptor callable
      attr_reader :decryptor

      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        queue_name: nil,
        payload_store_threshold: DEFAULT_PAYLOAD_STORE_THRESHOLD,
        **pool_options
      )
        pool_options[:shutdown_timeout] ||= 23
        pool_options[:user_agent] ||= "SolidQueue-AsyncHttp"
        pool_options[:logger] ||= (defined?(SolidQueue.logger) ? SolidQueue.logger : nil)

        super(**pool_options)

        @encryptor = nil
        @decryptor = nil

        self.queue_name = queue_name
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.payload_store_threshold = payload_store_threshold || DEFAULT_PAYLOAD_STORE_THRESHOLD
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

      def encryption(callable = nil, &block)
        @encryptor = resolve_callable(:encryption, callable, &block)
      end

      def decryption(callable = nil, &block)
        @decryptor = resolve_callable(:decryption, callable, &block)
      end

      def encrypt(data)
        return @encryptor.call(data) if @encryptor
        data
      end

      def decrypt(data)
        return @decryptor.call(data) if @decryptor
        data
      end

      def to_h
        super.merge(
          "payload_store_threshold" => payload_store_threshold,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "queue_name" => queue_name,
          "encryptor" => !@encryptor.nil?,
          "decryptor" => !@decryptor.nil?
        )
      end

      private

      def resolve_callable(name, callable = nil, &block)
        raise ArgumentError, "#{name} accepts either a callable argument or a block, not both" if callable && block
        raise ArgumentError, "#{name} callable must respond to #call" if callable && !callable.respond_to?(:call)
        callable || block
      end

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
