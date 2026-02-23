# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue do
  describe "VERSION" do
    it "has a version number" do
      expect(PatientHttp::SolidQueue::VERSION).to be_a(String)
    end
  end

  describe ".configure" do
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

  describe ".execute" do
    let(:callback_class) do
      klass = Class.new do
        def on_complete(response); end

        def on_error(error); end
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

  describe "HTTP convenience methods" do
    let(:callback_class) do
      klass = Class.new do
        def on_complete(response); end

        def on_error(error); end
      end
      stub_const("TestHttpCallback", klass)
      klass
    end

    %i[get post put patch delete].each do |method|
      it "enqueues a RequestJob for #{method}" do
        described_class.public_send(method, "https://example.com", callback: callback_class)
        job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
        expect(job[:job]).to eq(PatientHttp::SolidQueue::RequestJob)
      end
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
