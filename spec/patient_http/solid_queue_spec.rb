# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue do
  describe "VERSION" do
    it "has a version number" do
      expect(PatientHttp::SolidQueue::VERSION).to be_a(String)
    end
  end

  describe ".configure" do
    after do
      described_class.reset_configuration!
      PatientHttp.instance_variable_set(:@module_secrets, {})
      PatientHttp.default_configuration = nil
    end

    it "sets the built configuration as the PatientHttp default configuration" do
      config = described_class.configure { |c| }

      expect(PatientHttp.default_configuration).to be(config)
    end

    it "applies module-level secrets to the built configuration" do
      PatientHttp.register_secret("configure_spec_secret", "s3cret")

      config = described_class.configure { |c| }

      expect(config.secret_manager.include?("configure_spec_secret")).to be(true)
    end

    it "yields a Configuration object" do
      described_class.configure do |config|
        expect(config).to be_a(PatientHttp::SolidQueue::Configuration)
      end
    end

    it "stores the configuration" do
      described_class.configure do |config|
        config.max_connections = 5
      end
      expect(described_class.configuration.max_connections).to eq(5)
    end
  end

  describe ".configuration" do
    it "returns a Configuration with defaults" do
      expect(described_class.configuration).to be_a(PatientHttp::SolidQueue::Configuration)
    end
  end

  describe ".external_storage" do
    it "is reset by configure so it picks up the new configuration" do
      original_storage = described_class.external_storage

      described_class.configure { |c| }

      expect(described_class.external_storage).not_to be(original_storage)
    end

    it "is reset by reset_configuration!" do
      original_storage = described_class.external_storage

      described_class.reset_configuration!

      expect(described_class.external_storage).not_to be(original_storage)
    end
  end

  describe ".start" do
    let(:processor) do
      instance_double(
        PatientHttp::Processor,
        observe: nil,
        start: nil,
        drain: nil,
        stop: nil,
        running?: true,
        stopped?: false,
        config: PatientHttp::SolidQueue.configuration,
        tracked_request_ids: []
      )
    end

    before do
      allow(PatientHttp::Processor).to receive(:new).and_return(processor)
      allow(PatientHttp::SolidQueue::ProcessorObserver).to receive(:new).and_return(
        instance_double(PatientHttp::SolidQueue::ProcessorObserver)
      )
    end

    after do
      described_class.instance_variable_get(:@monitor_thread)&.stop
      described_class.instance_variable_set(:@monitor_thread, nil)
      described_class.instance_variable_set(:@task_monitor, nil)
      described_class.instance_variable_set(:@processors, {})
    end

    it "does not start a second processor when one is already running" do
      described_class.start
      described_class.start

      expect(PatientHttp::Processor).to have_received(:new).once
    end

    it "does not replace a draining processor" do
      described_class.start
      allow(processor).to receive(:running?).and_return(false)

      described_class.start

      expect(PatientHttp::Processor).to have_received(:new).once
      expect(described_class.processor).to be(processor)
    end

    it "starts a new processor after the previous one stopped" do
      described_class.start
      allow(processor).to receive(:stopped?).and_return(true)

      described_class.start

      expect(PatientHttp::Processor).to have_received(:new).twice
    end
  end

  describe ".execute" do
    let(:callback_class) do
      klass = Class.new do
        def on_complete(response)
        end

        def on_error(error)
        end
      end
      stub_const("TestCallback", klass)
      klass
    end

    it "enqueues a RequestJob" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      described_class.execute(request, callback: callback_class)
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(PatientHttp::SolidQueue::RequestJob)
    end

    it "returns a request ID string" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      result = described_class.execute(request, callback: callback_class)
      expect(result).to be_a(String)
    end
  end

  describe ".encrypt" do
    it "delegates to the configured encryptor" do
      encryptor = double("encryptor")
      allow(described_class.configuration).to receive(:encryptor).and_return(encryptor)
      expect(encryptor).to receive(:encrypt).with("value").and_return("encrypted")
      expect(described_class.encrypt("value")).to eq("encrypted")
    end
  end

  describe ".decrypt" do
    it "delegates to the configured encryptor" do
      encryptor = double("encryptor")
      allow(described_class.configuration).to receive(:encryptor).and_return(encryptor)
      expect(encryptor).to receive(:decrypt).with("encrypted").and_return("value")
      expect(described_class.decrypt("encrypted")).to eq("value")
    end
  end

  describe ".after_completion and .after_error" do
    it "registers completion callbacks" do
      invoked = false
      described_class.after_completion { |_r| invoked = true }
      described_class.invoke_completion_callbacks(double("response"))
      expect(invoked).to be true
    end

    it "registers error callbacks" do
      invoked = false
      described_class.after_error { |_e| invoked = true }
      described_class.invoke_error_callbacks(double("error"))
      expect(invoked).to be true
    end
  end
end
