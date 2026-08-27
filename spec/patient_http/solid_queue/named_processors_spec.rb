# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Named processors" do
  let(:callback_class) do
    klass = Class.new do
      def on_complete(response)
      end

      def on_error(error)
      end
    end
    stub_const("TestNamedProcessorCallback", klass)
    klass
  end

  let(:job_data) do
    {"job_class" => "PatientHttp::SolidQueue::RequestJob", "job_id" => SecureRandom.uuid, "arguments" => []}
  end

  after do
    PatientHttp::SolidQueue.reset!
  end

  describe "configuration profiles" do
    it "always includes a default profile" do
      config = PatientHttp::SolidQueue::Configuration.new
      expect(config.processor_profiles).to eq(default: {})
    end

    it "declares named profiles with option overrides" do
      config = PatientHttp::SolidQueue::Configuration.new
      config.processor(:llm, max_connections: 200, request_timeout: 120)
      config.processor(:webhooks, max_connections: 64)

      expect(config.processor_profiles.keys).to eq([:default, :llm, :webhooks])
      expect(config.processor_options(:llm)).to eq(max_connections: 200, request_timeout: 120)
    end

    it "declares a profile that inherits every option" do
      config = PatientHttp::SolidQueue::Configuration.new
      config.processor(:webhooks)

      expect(config.processor_profiles.keys).to include(:webhooks)
      expect(config.processor_config(:webhooks)).to be(config)
    end

    it "normalizes profile options through the option writers" do
      config = PatientHttp::SolidQueue::Configuration.new
      config.processor(:llm, protocol: "http1")

      expect(config.processor_options(:llm)).to eq(protocol: :http1)
      expect(config.processor_config(:llm).protocol).to eq(:http1)
    end

    it "rejects invalid profile options" do
      config = PatientHttp::SolidQueue::Configuration.new
      expect { config.processor(:bad, max_connections: 0) }.to raise_error(ArgumentError, /Invalid processor profile options/)
      expect { config.processor(:bad, no_such_option: 1) }.to raise_error(ArgumentError, /Invalid processor profile options/)
    end

    it "rejects an empty name" do
      config = PatientHttp::SolidQueue::Configuration.new
      expect { config.processor("", max_connections: 1) }.to raise_error(ArgumentError, /processor name cannot be empty/)
    end

    it "builds a profile configuration that inherits base options" do
      config = PatientHttp::SolidQueue::Configuration.new(max_connections: 100, request_timeout: 30)
      config.processor(:llm, max_connections: 200)

      llm_config = config.processor_config(:llm)
      expect(llm_config.max_connections).to eq(200)
      expect(llm_config.request_timeout).to eq(30)
      expect(config.processor_config(:default)).to be(config)
    end

    it "shares secrets with the base configuration" do
      config = PatientHttp::SolidQueue::Configuration.new
      config.register_secret(:token, "secret-value")
      config.processor(:llm, max_connections: 5)

      llm_config = config.processor_config(:llm)
      expect(llm_config.secret_manager.resolve_headers("authorization" => PatientHttp.secret(:token))).to eq(
        "authorization" => "secret-value"
      )
    end

    it "raises for an unknown profile" do
      config = PatientHttp::SolidQueue::Configuration.new
      expect { config.processor_config(:nope) }.to raise_error(ArgumentError, /Unknown processor profile/)
    end
  end

  describe "lifecycle" do
    before do
      PatientHttp::SolidQueue.configure do |config|
        config.max_connections = 50
        config.processor(:llm, max_connections: 20, request_timeout: 120)
        config.processor(:webhooks, max_connections: 10, request_timeout: 10)
      end
    end

    it "starts one processor per profile with its own configuration" do
      PatientHttp::SolidQueue.start

      default_processor = PatientHttp::SolidQueue.processor
      llm_processor = PatientHttp::SolidQueue.processor(:llm)
      webhook_processor = PatientHttp::SolidQueue.processor(:webhooks)

      expect(default_processor).to be_running
      expect(llm_processor).to be_running
      expect(webhook_processor).to be_running

      expect(default_processor.config.max_connections).to eq(50)
      expect(llm_processor.config.max_connections).to eq(20)
      expect(llm_processor.config.request_timeout).to eq(120)
      expect(webhook_processor.config.max_connections).to eq(10)
      expect(llm_processor.name).to eq("llm")
    end

    it "drains and stops all processors" do
      PatientHttp::SolidQueue.start
      processors = [:default, :llm, :webhooks].map { |name| PatientHttp::SolidQueue.processor(name) }

      PatientHttp::SolidQueue.quiet
      expect(processors).to all(be_draining)

      PatientHttp::SolidQueue.stop
      expect(processors).to all(be_stopped)
      expect(PatientHttp::SolidQueue.processor).to be_nil
    end

    it "records the summed max connections in the process registration" do
      PatientHttp::SolidQueue.start

      registration = PatientHttp::SolidQueue::ProcessRegistration.last
      expect(registration.max_connections).to eq(80)
    end
  end

  describe "routing" do
    before do
      PatientHttp::SolidQueue.configure { |config| config.processor(:llm) }
    end

    it "serializes the processor name into the RequestJob arguments" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::SolidQueue.execute(request, callback: callback_class, processor: :llm)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args].last).to eq("llm")
    end

    it "uses the request's own processor name when no explicit option is given" do
      request = PatientHttp::Request.new(:get, "https://example.com", processor: :llm)
      PatientHttp::SolidQueue.execute(request, callback: callback_class)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args].last).to eq("llm")
    end

    it "defaults to the default processor" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::SolidQueue.execute(request, callback: callback_class)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args].last).to eq("default")
    end

    it "raises for a processor profile that is not configured" do
      request = PatientHttp::Request.new(:get, "https://example.com")

      expect {
        PatientHttp::SolidQueue.execute(request, callback: callback_class, processor: :nope)
      }.to raise_error(PatientHttp::UnknownProcessorError, /nope/)
    end
  end

  describe "execution on a named processor" do
    before do
      allow(PatientHttp::SolidQueue::RequestExecutor).to receive(:async_disabled?).and_return(false)
    end

    it "enqueues the task on the processor named in the job" do
      PatientHttp::SolidQueue.configure do |config|
        config.processor(:llm, max_connections: 20)
      end
      PatientHttp::SolidQueue.start

      captured = nil
      allow(PatientHttp::SolidQueue.processor(:llm)).to receive(:enqueue) { |task| captured = task }

      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::SolidQueue::RequestExecutor.execute(
        request,
        callback: callback_class,
        active_job_data: job_data,
        processor_name: "llm"
      )

      expect(captured).to be_a(PatientHttp::RequestTask)
    end

    it "raises UnknownProcessorError for a job naming an unconfigured processor" do
      PatientHttp::SolidQueue.start

      request = PatientHttp::Request.new(:get, "https://example.com")
      expect do
        PatientHttp::SolidQueue::RequestExecutor.execute(
          request,
          callback: callback_class,
          active_job_data: job_data,
          processor_name: "nope"
        )
      end.to raise_error(PatientHttp::UnknownProcessorError, /nope/)
    end

    it "rejects without touching the crash-recovery registry when the processor is full" do
      PatientHttp::SolidQueue.start
      processor = PatientHttp::SolidQueue.processor
      allow(processor).to receive(:capacity_available?).and_return(false)

      request = PatientHttp::Request.new(:get, "https://example.com")
      expect do
        PatientHttp::SolidQueue::RequestExecutor.execute(
          request,
          callback: callback_class,
          active_job_data: job_data
        )
      end.to raise_error(PatientHttp::MaxCapacityError)

      expect(PatientHttp::SolidQueue::InflightRequest.count).to eq(0)
    end
  end
end
