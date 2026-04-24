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

  describe "#to_h" do
    it "includes all configuration keys" do
      h = config.to_h
      expect(h).to include("heartbeat_interval", "orphan_threshold", "payload_store_threshold")
    end
  end
end
