# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::TaskHandler do
  let(:job_data) do
    {"job_class" => "PatientHttp::SolidQueue::RequestJob", "job_id" => "test-id", "arguments" => [], "queue_name" => "default", "executions" => 0}
  end

  subject(:handler) { described_class.new(job_data) }

  describe "#job_id" do
    it "returns the job_id from active_job_data" do
      expect(handler.job_id).to eq("test-id")
    end
  end

  describe "#on_complete" do
    it "enqueues a CallbackJob" do
      response = instance_double(PatientHttp::Response)
      allow(response).to receive(:as_json).and_return({"status" => 200})

      handler.on_complete(response, "TestHandlerCallback")

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(PatientHttp::SolidQueue::CallbackJob)
      expect(job[:args][1]).to eq("response")
      expect(job[:args][2]).to eq("TestHandlerCallback")
    end
  end

  describe "#on_error" do
    it "enqueues a CallbackJob with error" do
      error = instance_double(PatientHttp::HttpError)
      allow(error).to receive(:as_json).and_return({"error_type" => "timeout"})

      handler.on_error(error, "TestHandlerCallback")

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(PatientHttp::SolidQueue::CallbackJob)
      expect(job[:args][1]).to eq("error")
      expect(job[:args][2]).to eq("TestHandlerCallback")
    end
  end

  describe "stored request payload cleanup" do
    let(:response) do
      response = instance_double(PatientHttp::Response)
      allow(response).to receive(:as_json).and_return({"status" => 200})
      response
    end

    let(:error) do
      error = instance_double(PatientHttp::HttpError)
      allow(error).to receive(:as_json).and_return({"error_type" => "timeout"})
      error
    end

    before do
      TestPayloadStore.clear!
      PatientHttp::SolidQueue.configure do |c|
        c.register_payload_store(:test_store, adapter: :test_store)
      end
    end

    after { PatientHttp::SolidQueue.reset_configuration! }

    def request_job_data_with_stored_payload
      stored_ref = PatientHttp::SolidQueue.external_storage.store(
        {"http_method" => "get", "url" => "http://example.com/test"}
      )
      {
        "job_class" => PatientHttp::SolidQueue::RequestJob.name,
        "job_id" => "request-job-id",
        "arguments" => [stored_ref, "TestHandlerCallback", false, nil, "req-1"],
        "queue_name" => "default",
        "executions" => 0
      }
    end

    it "deletes the stored request payload when the request completes" do
      handler = described_class.new(request_job_data_with_stored_payload)
      handler.on_complete(response, "TestHandlerCallback")

      expect(TestPayloadStore.payloads).to be_empty
    end

    it "deletes the stored request payload when the request errors" do
      handler = described_class.new(request_job_data_with_stored_payload)
      handler.on_error(error, "TestHandlerCallback")

      expect(TestPayloadStore.payloads).to be_empty
    end

    it "does not delete the stored request payload when the job is retried" do
      handler = described_class.new(request_job_data_with_stored_payload)
      handler.retry

      expect(TestPayloadStore.payloads).not_to be_empty
    end

    it "does not delete arguments of other job classes" do
      stored_ref = PatientHttp::SolidQueue.external_storage.store({"some" => "data"})
      handler = described_class.new(
        "job_class" => "TestJob",
        "job_id" => "other-job-id",
        "arguments" => [stored_ref],
        "queue_name" => "default",
        "executions" => 0
      )
      handler.on_complete(response, "TestHandlerCallback")

      expect(TestPayloadStore.payloads).not_to be_empty
    end
  end
end
