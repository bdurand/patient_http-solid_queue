# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::RequestJob do
  let(:callback_class) do
    klass = Class.new do
      def on_complete(response)
      end

      def on_error(error)
      end
    end
    stub_const("TestRequestCallback", klass)
    klass
  end

  it "is an ActiveJob::Base subclass" do
    expect(described_class.superclass).to eq(ActiveJob::Base)
  end

  it "sets the context during perform" do
    captured_context = nil

    allow(PatientHttp::SolidQueue::RequestExecutor).to receive(:execute) do |_, **_kwargs|
      captured_context = PatientHttp::SolidQueue::Context.current_job
    end

    request = PatientHttp::Request.new(:get, "https://example.com")
    data = request.as_json

    job = described_class.new(data, callback_class.name, false, nil, SecureRandom.uuid)
    job.perform_now

    expect(captured_context).not_to be_nil
    expect(captured_context["job_class"]).to eq(described_class.name)
  end
end
