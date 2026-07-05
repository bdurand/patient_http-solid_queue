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

  describe "retries" do
    let(:request_data) { PatientHttp::Request.new(:get, "https://example.com").as_json }

    it "retries the job when the processor is at max capacity" do
      allow(PatientHttp::SolidQueue::RequestExecutor).to receive(:execute)
        .and_raise(PatientHttp::MaxCapacityError.new("at max capacity"))

      described_class.new(request_data, callback_class.name, false, nil, SecureRandom.uuid).perform_now

      retried_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(retried_job[:job]).to eq(described_class)
    end

    it "retries the job when the processor is not running" do
      allow(PatientHttp::SolidQueue::RequestExecutor).to receive(:execute)
        .and_raise(PatientHttp::NotRunningError.new("not running"))

      described_class.new(request_data, callback_class.name, false, nil, SecureRandom.uuid).perform_now

      retried_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(retried_job[:job]).to eq(described_class)
    end
  end

  context "with external storage" do
    let(:stored_ref) do
      request = PatientHttp::Request.new(:get, "http://example.com/test")
      PatientHttp::SolidQueue.external_storage.store(request.as_json)
    end

    before do
      TestPayloadStore.clear!
      PatientHttp::SolidQueue.configure do |c|
        c.register_payload_store(:test_store, adapter: :test_store)
      end
    end

    after { PatientHttp::SolidQueue.reset_configuration! }

    it "keeps the stored payload after submitting the request" do
      allow(PatientHttp::SolidQueue::RequestExecutor).to receive(:execute)

      described_class.new.perform(stored_ref, callback_class.name, false, nil, SecureRandom.uuid)

      expect(TestPayloadStore.payloads).not_to be_empty
    end

    it "keeps the stored payload when the request cannot be enqueued so retries can fetch it" do
      allow(PatientHttp::SolidQueue::RequestExecutor).to receive(:execute)
        .and_raise(PatientHttp::MaxCapacityError.new("at max capacity"))

      expect {
        described_class.new.perform(stored_ref, callback_class.name, false, nil, SecureRandom.uuid)
      }.to raise_error(PatientHttp::MaxCapacityError)

      expect(TestPayloadStore.payloads).not_to be_empty
    end

    describe "after_discard" do
      it "deletes the stored payload for dead jobs" do
        job = described_class.new(stored_ref, callback_class.name, false, nil, "req-1")

        job.send(:run_after_discard_procs, RuntimeError.new("exhausted"))

        expect(TestPayloadStore.payloads).to be_empty
      end

      it "does not raise for jobs without stored payloads" do
        job = described_class.new({"http_method" => "get", "url" => "http://example.com/test"}, callback_class.name, false, nil, "req-1")

        expect {
          job.send(:run_after_discard_procs, RuntimeError.new("exhausted"))
        }.not_to raise_error
      end
    end
  end
end
