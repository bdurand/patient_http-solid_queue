# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::RequestExecutor do
  let(:callback_class) do
    klass = Class.new do
      def on_complete(response)
      end

      def on_error(error)
      end
    end
    stub_const("TestExecutorCallback", klass)
    klass
  end

  let(:request) { PatientHttp::Request.new(:get, "https://example.com") }

  let(:job_data) do
    {"job_class" => "PatientHttp::SolidQueue::RequestJob", "job_id" => SecureRandom.uuid, "arguments" => []}
  end

  describe ".execute" do
    it "raises if active_job_data is nil and no context" do
      expect {
        described_class.execute(request, callback: callback_class, active_job_data: nil)
      }.to raise_error(ArgumentError, /active_job_data is required/)
    end

    it "raises if active_job_data has no job_class" do
      bad_data = {"arguments" => []}
      expect {
        described_class.execute(request, callback: callback_class, active_job_data: bad_data)
      }.to raise_error(ArgumentError, /job_class/)
    end

    it "raises if active_job_data has no arguments array" do
      bad_data = {"job_class" => "Foo"}
      expect {
        described_class.execute(request, callback: callback_class, active_job_data: bad_data)
      }.to raise_error(ArgumentError, /arguments/)
    end

    it "executes synchronously in testing mode" do
      # PatientHttp.testing? is true in test env
      result = described_class.execute(
        request,
        callback: callback_class,
        active_job_data: job_data
      )
      expect(result).to be_a(String)
    end

    it "uses the configured raise_error_responses when the value is omitted" do
      PatientHttp::SolidQueue.configuration.raise_error_responses = true
      allow(PatientHttp::RequestTask).to receive(:new).and_call_original

      described_class.execute(request, callback: callback_class, active_job_data: job_data)

      expect(PatientHttp::RequestTask).to have_received(:new).with(hash_including(raise_error_responses: true))
    ensure
      PatientHttp::SolidQueue.reset_configuration!
    end

    it "raises UnknownProcessorError for an empty processor name" do
      allow(PatientHttp).to receive(:testing?).and_return(false)

      expect {
        described_class.execute(request, callback: callback_class, active_job_data: job_data, processor_name: "")
      }.to raise_error(PatientHttp::UnknownProcessorError)
    end
  end
end
