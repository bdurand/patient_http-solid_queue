# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::Context do
  describe ".current_job" do
    it "returns nil when no job is set" do
      expect(described_class.current_job).to be_nil
    end
  end

  describe ".with_job" do
    let(:job_data) { {"job_class" => "TestJob", "job_id" => "abc123", "arguments" => []} }

    it "sets and clears the current job" do
      described_class.with_job(job_data) do
        expect(described_class.current_job).to eq(job_data)
      end
      expect(described_class.current_job).to be_nil
    end

    it "restores the previous job after the block" do
      outer = {"job_class" => "Outer", "job_id" => "1", "arguments" => []}
      inner = {"job_class" => "Inner", "job_id" => "2", "arguments" => []}

      described_class.with_job(outer) do
        described_class.with_job(inner) do
          expect(described_class.current_job).to eq(inner)
        end
        expect(described_class.current_job).to eq(outer)
      end
    end

    it "clears the job even if an exception is raised" do
      job_data = {"job_class" => "TestJob", "job_id" => "abc", "arguments" => []}
      expect {
        described_class.with_job(job_data) { raise "error" }
      }.to raise_error("error")
      expect(described_class.current_job).to be_nil
    end
  end
end
