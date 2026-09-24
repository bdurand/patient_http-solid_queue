# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue do
  describe "VERSION" do
    it "has a version number" do
      expect(PatientHttp::SolidQueue::VERSION).to be_a(String)
    end
  end

  describe "setup" do
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

    it "registers the request handler when the gem is loaded" do
      expect(PatientHttp.handler_registered?).to be(true)
    end

    it "registers itself as the PatientHttp configuration provider" do
      expect(PatientHttp.configuration_provider).to be(described_class)
      expect(PatientHttp.configuration).to be_a(PatientHttp::SolidQueue::Configuration)
    end

    it "enqueues requests made through PatientHttp without any configure call" do
      PatientHttp.get("https://example.com/unconfigured", callback: callback_class)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(PatientHttp::SolidQueue::RequestJob)
    end

    it "keeps the handler registered after the processor stops" do
      described_class.start
      described_class.stop(timeout: 0)

      expect(PatientHttp.handler_registered?).to be(true)
    end
  end

  describe ".configure" do
    after do
      described_class.reset_configuration!
      PatientHttp.instance_variable_set(:@module_secrets, {})
      PatientHttp.default_configuration = nil
    end

    it "logs a warning when the configuration changes while processors run" do
      output = StringIO.new
      described_class.configuration.logger = Logger.new(output)
      allow(described_class).to receive(:running?).and_return(true)

      described_class.configure { |c| c.max_connections = 128 }

      expect(output.string).to include("Configuration changed while processors are running")
    end

    it "does not warn when the configuration changes before processors run" do
      output = StringIO.new
      described_class.configuration.logger = Logger.new(output)

      described_class.configure { |c| c.max_connections = 128 }

      expect(output.string).to be_empty
    end

    it "yields the same configuration on every call so options accumulate" do
      described_class.configure { |c| c.max_connections = 512 }
      described_class.configure { |c| c.request_timeout = 120 }

      expect(described_class.configuration.max_connections).to eq(512)
      expect(described_class.configuration.request_timeout).to eq(120)
    end

    it "is reachable through PatientHttp.configure without naming the integration" do
      config = PatientHttp.configure { |c| c.max_connections = 321 }

      expect(config).to be_a(PatientHttp::SolidQueue::Configuration)
      expect(described_class.configuration.max_connections).to eq(321)
    end

    it "applies module-level secrets registered after the configuration exists" do
      described_class.configure { |c| }

      PatientHttp.register_secret("late_secret", "s3cret")

      expect(described_class.configuration.secret_manager.include?("late_secret")).to be(true)
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
    it "uses the current configuration after the configuration is replaced" do
      described_class.external_storage

      PatientHttp.default_configuration = nil

      expect(described_class.external_storage.config).to be(described_class.configuration)
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

  describe ".stop" do
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

    it "logs a processor stop error and still shuts down the shared services" do
      log = StringIO.new
      described_class.configure { |c| c.logger = Logger.new(log) }
      described_class.start
      allow(described_class.processor).to receive(:stop).and_wrap_original do |original, **options|
        original.call(**options)
        raise "boom"
      end

      expect { described_class.stop(timeout: 0) }.not_to raise_error

      expect(log.string).to match(/Failed to stop processor default: .*boom/)
      expect(described_class.processor).to be_nil
      expect(described_class.instance_variable_get(:@monitor_thread)).to be_nil
      expect(PatientHttp::SolidQueue::ProcessRegistration.count).to eq(0)
    end

    it "keeps the request handler registered so requests made while stopping are enqueued" do
      described_class.start
      described_class.stop

      request = PatientHttp::Request.new(:get, "https://example.com")
      request_id = PatientHttp.execute(request: request, callback: callback_class)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(PatientHttp.handler_registered?).to be(true)
      expect(job[:job]).to eq(PatientHttp::SolidQueue::RequestJob)
      expect(job[:args][4]).to eq(request_id)
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

    it "uses the configured raise_error_responses when none is given" do
      described_class.configuration.raise_error_responses = true
      request = PatientHttp::Request.new(:get, "https://example.com")
      described_class.execute(request, callback: callback_class)
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args][2]).to be true
    end

    it "uses the raise_error_responses from the module methods' default" do
      described_class.configuration.raise_error_responses = true
      PatientHttp.get("https://example.com", callback: callback_class)
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args][2]).to be true
    end

    it "uses an explicit raise_error_responses over the configuration" do
      described_class.configuration.raise_error_responses = true
      request = PatientHttp::Request.new(:get, "https://example.com")
      described_class.execute(request, callback: callback_class, raise_error_responses: false)
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args][2]).to be false
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
