# frozen_string_literal: true

require "active_support/key_generator"
require "active_support/message_encryptor"

module PatientHttp
  module SolidQueue
    # Configuration for the Solid Queue Async HTTP gem.
    #
    # Wraps PatientHttp::Configuration with Solid Queue-aware defaults and adds
    # Solid Queue-specific options like queue name settings.
    class Configuration < PatientHttp::Configuration
      # Default threshold in bytes above which payloads are stored externally.
      DEFAULT_PAYLOAD_STORE_THRESHOLD = 64 * 1024 # 64KB

      # Salt used for deriving encryption keys via ActiveSupport::KeyGenerator.
      ENCRYPTION_SALT = "PatientHttp::SolidQueue"

      # Key length in bytes for AES-256-GCM.
      ENCRYPTION_KEY_LENGTH = 32

      # Minimum acceptable length for user-provided encryption key strings.
      ENCRYPTION_MIN_KEY_LENGTH = 16

      # @return [Integer] Size threshold in bytes for external payload storage
      attr_reader :payload_store_threshold

      # @return [Numeric] Orphan detection threshold in seconds
      attr_reader :orphan_threshold

      # @return [Numeric] Heartbeat update interval in seconds
      attr_reader :heartbeat_interval

      # @return [String, nil] Queue name for RequestJob and CallbackJob
      attr_reader :queue_name

      # @return [String, Array<String>, nil] The configured encryption key or keys
      attr_reader :encryption_key

      # Buffer in seconds subtracted from SolidQueue.shutdown_timeout to derive
      # the default shutdown_timeout for this gem's connection pool.
      SHUTDOWN_TIMEOUT_BUFFER = 2

      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        queue_name: nil,
        encryption_key: nil,
        payload_store_threshold: DEFAULT_PAYLOAD_STORE_THRESHOLD,
        **pool_options
      )
        if ::SolidQueue.shutdown_timeout
          pool_options[:shutdown_timeout] ||= [::SolidQueue.shutdown_timeout - SHUTDOWN_TIMEOUT_BUFFER, 1].max
        end
        pool_options[:user_agent] ||= "SolidQueue-AsyncHttp"
        pool_options[:logger] ||= (defined?(SolidQueue.logger) ? SolidQueue.logger : nil)

        super(**pool_options)

        @encryption_key = nil
        @message_encryptor = nil

        self.queue_name = queue_name
        self.encryption_key = encryption_key
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.payload_store_threshold = payload_store_threshold || DEFAULT_PAYLOAD_STORE_THRESHOLD
      end

      # Set the encryption key used to encrypt and decrypt request/response data.
      #
      # Accepts a single key string, an array of key strings for key rotation,
      # or nil to disable encryption. When an array is provided, the first key
      # is used for encryption and all keys are tried during decryption.
      #
      # @param value [String, Array<String>, nil] the encryption key(s)
      def encryption_key=(value)
        if value.nil?
          @encryption_key = nil
          @message_encryptor = nil
          return
        end

        keys = Array(value)
        validate_encryption_keys!(keys)

        primary_key = derive_key(keys.first)
        @message_encryptor = ActiveSupport::MessageEncryptor.new(primary_key, serializer: JSON)

        keys.drop(1).each do |old_key|
          @message_encryptor.rotate(derive_key(old_key))
        end

        @encryption_key = value
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

      # Encrypt data using the configured encryption key.
      #
      # @param data [Hash] the data to encrypt
      # @return [String, Hash] encrypted string if encryption is configured, otherwise the original data
      def encrypt(data)
        return @message_encryptor.encrypt_and_sign(data) if @message_encryptor
        data
      end

      # Decrypt data using the configured encryption key(s).
      #
      # When key rotation is configured, each key is tried in order until
      # decryption succeeds.
      #
      # @param data [String, Hash] encrypted string or unencrypted hash
      # @return [Hash] the decrypted data
      def decrypt(data)
        return @message_encryptor.decrypt_and_verify(data) if @message_encryptor
        data
      end

      # @return [Hash] configuration as a hash for logging/inspection
      def to_h
        super.merge(
          "payload_store_threshold" => payload_store_threshold,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "queue_name" => queue_name,
          "encryption" => !@encryption_key.nil?
        )
      end

      private

      def derive_key(secret)
        ActiveSupport::KeyGenerator.new(secret).generate_key(ENCRYPTION_SALT, ENCRYPTION_KEY_LENGTH)
      end

      def validate_encryption_keys!(keys)
        raise ArgumentError, "encryption_key must not be an empty array" if keys.empty?

        keys.each do |key|
          unless key.is_a?(String)
            raise ArgumentError, "encryption_key must be a String or Array of Strings, got: #{key.class}"
          end
          if key.length < ENCRYPTION_MIN_KEY_LENGTH
            raise ArgumentError, "encryption_key must be at least #{ENCRYPTION_MIN_KEY_LENGTH} characters"
          end
        end
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
