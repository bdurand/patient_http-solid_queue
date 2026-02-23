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
end
