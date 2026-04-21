# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::Configuration do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "sets user_agent to SolidQueue-AsyncHttp" do
      expect(config.user_agent).to eq("SolidQueue-AsyncHttp")
    end

    it "sets heartbeat_interval to 60" do
      expect(config.heartbeat_interval).to eq(60)
    end

    it "sets orphan_threshold to 300" do
      expect(config.orphan_threshold).to eq(300)
    end

    it "sets payload_store_threshold to 64KB" do
      expect(config.payload_store_threshold).to eq(64 * 1024)
    end

    it "sets shutdown_timeout based on SolidQueue.shutdown_timeout" do
      expect(config.shutdown_timeout).to eq(SolidQueue.shutdown_timeout - described_class::SHUTDOWN_TIMEOUT_BUFFER)
    end
  end

  describe "#heartbeat_interval=" do
    it "raises if not positive" do
      expect { config.heartbeat_interval = 0 }.to raise_error(ArgumentError)
    end

    it "raises if heartbeat_interval >= orphan_threshold" do
      expect { config.heartbeat_interval = 400 }.to raise_error(ArgumentError)
    end
  end

  describe "#orphan_threshold=" do
    it "raises if not positive" do
      expect { config.orphan_threshold = -1 }.to raise_error(ArgumentError)
    end
  end

  describe "#queue_name=" do
    it "accepts a string queue name" do
      config.queue_name = "background"
      expect(config.queue_name).to eq("background")
    end

    it "raises if not a string" do
      expect { config.queue_name = 123 }.to raise_error(ArgumentError)
    end

    it "accepts nil" do
      config.queue_name = nil
      expect(config.queue_name).to be_nil
    end
  end

  describe "#encryption_key=" do
    it "accepts a string key" do
      config.encryption_key = "a-secret-key-that-is-long-enough"
      expect(config.encryption_key).to eq("a-secret-key-that-is-long-enough")
    end

    it "accepts an array of keys for rotation" do
      keys = ["new-primary-key-long-enough", "old-key-still-long-enough"]
      config.encryption_key = keys
      expect(config.encryption_key).to eq(keys)
    end

    it "accepts nil to disable encryption" do
      config.encryption_key = "a-secret-key-that-is-long-enough"
      config.encryption_key = nil
      expect(config.encryption_key).to be_nil
    end

    it "raises if not a String or Array" do
      expect { config.encryption_key = 123 }.to raise_error(ArgumentError, /String/)
    end

    it "raises if key is too short" do
      expect { config.encryption_key = "short" }.to raise_error(ArgumentError, /at least/)
    end

    it "raises if array contains a non-string" do
      expect { config.encryption_key = ["valid-key-long-enough!", 123] }.to raise_error(ArgumentError, /String/)
    end

    it "raises if array contains a short key" do
      expect { config.encryption_key = ["valid-key-long-enough!", "short"] }.to raise_error(ArgumentError, /at least/)
    end

    it "raises if array is empty" do
      expect { config.encryption_key = [] }.to raise_error(ArgumentError, /empty/)
    end
  end

  describe "#encrypt / #decrypt" do
    it "returns data unchanged when no encryption key is set" do
      data = {"key" => "value"}
      expect(config.encrypt(data)).to eq(data)
      expect(config.decrypt(data)).to eq(data)
    end

    context "with a single encryption key" do
      before { config.encryption_key = "a-secret-key-that-is-long-enough" }

      it "encrypts data to a string" do
        data = {"key" => "value"}
        encrypted = config.encrypt(data)
        expect(encrypted).to be_a(String)
        expect(encrypted).not_to include("value")
      end

      it "round-trips encrypt and decrypt" do
        data = {"key" => "value", "nested" => {"a" => 1}}
        expect(config.decrypt(config.encrypt(data))).to eq(data)
      end
    end

    context "with key rotation" do
      let(:old_key) { "old-secret-key-for-rotation" }
      let(:new_key) { "new-secret-key-for-rotation" }

      it "decrypts data encrypted with the old key after rotation" do
        config.encryption_key = old_key
        data = {"key" => "value"}
        encrypted_with_old = config.encrypt(data)

        config.encryption_key = [new_key, old_key]
        expect(config.decrypt(encrypted_with_old)).to eq(data)
      end

      it "encrypts new data with the primary (first) key" do
        config.encryption_key = [new_key, old_key]
        data = {"key" => "value"}
        encrypted = config.encrypt(data)

        # Verify it can be decrypted with only the new key
        config.encryption_key = new_key
        expect(config.decrypt(encrypted)).to eq(data)
      end
    end
  end

  describe "#to_h" do
    it "includes all configuration keys" do
      h = config.to_h
      expect(h).to include("heartbeat_interval", "orphan_threshold", "payload_store_threshold")
    end

    it "reports encryption as false when no key is set" do
      expect(config.to_h["encryption"]).to be false
    end

    it "reports encryption as true when a key is set" do
      config.encryption_key = "a-secret-key-that-is-long-enough"
      expect(config.to_h["encryption"]).to be true
    end
  end
end
