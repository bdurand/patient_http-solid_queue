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
end
