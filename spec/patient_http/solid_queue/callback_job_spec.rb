# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::CallbackJob do
  it "is an ActiveJob::Base subclass" do
    expect(described_class.superclass).to eq(ActiveJob::Base)
  end

  let(:callback_class) do
    klass = Class.new do
      attr_reader :received

      def on_complete(response)
        @received = [:complete, response]
      end

      def on_error(error)
        @received = [:error, error]
      end
    end
    stub_const("TestCallbackJobService", klass)
    klass
  end

  it "invokes on_complete for response result_type" do
    response = instance_double(PatientHttp::Response)
    allow(PatientHttp::Response).to receive(:load).and_return(response)
    allow(PatientHttp::SolidQueue).to receive(:invoke_completion_callbacks)

    instance = callback_class.new
    allow(callback_class).to receive(:new).and_return(instance)

    described_class.new({"type" => "response"}, "response", callback_class.name).perform_now

    expect(instance.received[0]).to eq(:complete)
  end

  it "invokes on_error for error result_type" do
    error = instance_double(PatientHttp::HttpError)
    allow(PatientHttp::Error).to receive(:load).and_return(error)
    allow(PatientHttp::SolidQueue).to receive(:invoke_error_callbacks)

    instance = callback_class.new
    allow(callback_class).to receive(:new).and_return(instance)

    described_class.new({"type" => "error"}, "error", callback_class.name).perform_now

    expect(instance.received[0]).to eq(:error)
  end

  describe "after_discard" do
    let(:error_data) do
      {
        "message" => "Network error",
        "code" => "network_failure",
        "callback_args" => {}
      }
    end

    let(:exception) { RuntimeError.new("exhausted") }

    before do
      allow(PatientHttp::SolidQueue.external_storage).to receive(:storage_ref?).and_return(false)
      allow(PatientHttp::SolidQueue.external_storage).to receive(:delete)
      allow(PatientHttp::SolidQueue).to receive(:decrypt) { |d| d }
    end

    after { PatientHttp::SolidQueue.reset_configuration! }

    it "calls the on_retries_exhausted handler with the error" do
      received_error = nil
      PatientHttp::SolidQueue.configure do |c|
        c.on_retries_exhausted = ->(error) { received_error = error }
      end

      job = described_class.new(error_data, "error", "TestCallback")
      job.send(:run_after_discard_procs, exception)

      expect(received_error).to be_a(PatientHttp::Error)
      expect(received_error.message).to eq("Network error")
    end

    it "does not raise if no handler is configured" do
      PatientHttp::SolidQueue.configure { |c| }

      job = described_class.new(error_data, "error", "TestCallback")

      expect {
        job.send(:run_after_discard_procs, exception)
      }.not_to raise_error
    end

    it "does not call the handler for response result_type" do
      called = false
      PatientHttp::SolidQueue.configure do |c|
        c.on_retries_exhausted = ->(_error) { called = true }
      end

      job = described_class.new(error_data, "response", "TestCallback")
      job.send(:run_after_discard_procs, exception)

      expect(called).to be false
    end

    it "logs a warning if the handler raises" do
      PatientHttp::SolidQueue.configure do |c|
        c.on_retries_exhausted = ->(_error) { raise "handler error" }
      end

      job = described_class.new(error_data, "error", "TestCallback")

      expect(PatientHttp::SolidQueue.configuration.logger).to receive(:warn).with(
        /on_retries_exhausted handler failed/
      )

      job.send(:run_after_discard_procs, exception)
    end

    it "deletes the external storage payload" do
      PatientHttp::SolidQueue.configure { |c| }

      job = described_class.new(error_data, "error", "TestCallback")
      job.send(:run_after_discard_procs, exception)

      expect(PatientHttp::SolidQueue.external_storage).to have_received(:delete).with(error_data)
    end
  end
end
