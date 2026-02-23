# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::ProcessorObserver do
  let(:config) { PatientHttp::SolidQueue::Configuration.new }
  let(:processor) do
    dbl = instance_double(PatientHttp::Processor)
    allow(dbl).to receive(:config).and_return(config)
    allow(dbl).to receive(:inflight_request_ids).and_return([])
    dbl
  end

  subject(:observer) { described_class.new(processor) }

  it "creates a task_monitor" do
    expect(observer.task_monitor).to be_a(PatientHttp::SolidQueue::TaskMonitor)
  end

  describe "#request_start and #request_end" do
    let(:task_handler) do
      job_data = {"job_class" => "PatientHttp::SolidQueue::RequestJob", "job_id" => SecureRandom.uuid, "arguments" => []}
      PatientHttp::SolidQueue::TaskHandler.new(job_data)
    end

    let(:request_task) do
      task = instance_double(PatientHttp::RequestTask)
      allow(task).to receive(:id).and_return(SecureRandom.uuid)
      allow(task).to receive(:task_handler).and_return(task_handler)
      task
    end

    it "registers on request_start" do
      observer.request_start(request_task)
      expect(observer.task_monitor.registered?(request_task)).to be true
    end

    it "unregisters on request_end" do
      observer.request_start(request_task)
      observer.request_end(request_task)
      expect(observer.task_monitor.registered?(request_task)).to be false
    end
  end
end
