# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::ProcessorObserver do
  let(:config) { PatientHttp::SolidQueue::Configuration.new }
  let(:task_monitor) { PatientHttp::SolidQueue::TaskMonitor.new(config) }
  let(:processor) do
    dbl = instance_double(PatientHttp::Processor)
    allow(dbl).to receive(:config).and_return(config)
    allow(dbl).to receive(:tracked_request_ids).and_return([])
    dbl
  end

  subject(:observer) { described_class.new(processor, task_monitor: task_monitor) }

  let(:task_handler) do
    job_data = {"job_class" => "PatientHttp::SolidQueue::RequestJob", "job_id" => SecureRandom.uuid, "arguments" => []}
    PatientHttp::SolidQueue::TaskHandler.new(job_data)
  end

  def build_task(started: false)
    task = instance_double(PatientHttp::RequestTask)
    allow(task).to receive(:id).and_return(SecureRandom.uuid)
    allow(task).to receive(:task_handler).and_return(task_handler)
    allow(task).to receive(:started?).and_return(started)
    task
  end

  it "exposes the shared task_monitor" do
    expect(observer.task_monitor).to be(task_monitor)
  end

  describe "#request_enqueued and #request_end" do
    it "registers on request_enqueued" do
      task = build_task
      observer.request_enqueued(task)
      expect(task_monitor.registered?(task)).to be true
    end

    it "unregisters on request_end" do
      task = build_task
      observer.request_enqueued(task)
      observer.request_end(task)
      expect(task_monitor.registered?(task)).to be false
    end

    it "unregisters on request_rejected" do
      task = build_task
      observer.request_enqueued(task)
      observer.request_rejected(task)
      expect(task_monitor.registered?(task)).to be false
    end
  end

  describe "#request_requeued" do
    it "unregisters the task" do
      task = build_task(started: true)
      observer.request_enqueued(task)
      observer.request_requeued(task)
      expect(task_monitor.registered?(task)).to be false
    end

    it "suppresses the trailing request_end for a started task" do
      task = build_task(started: true)
      observer.request_enqueued(task)
      observer.request_requeued(task)

      # Re-register to prove request_end does not remove the entry again: the
      # job system owns the request, so a fresh registration (from the retried
      # job) must survive the trailing request_end of the shutdown sequence.
      observer.request_enqueued(task)
      observer.request_end(task)
      expect(task_monitor.registered?(task)).to be true
    end

    it "does not remember never-started tasks (they get no request_end)" do
      task = build_task(started: false)
      observer.request_requeued(task)

      observer.request_enqueued(task)
      observer.request_end(task)
      expect(task_monitor.registered?(task)).to be false
    end
  end

  describe "#completion_failed" do
    it "keeps the crash-recovery record" do
      task = build_task(started: true)
      observer.request_enqueued(task)

      observer.completion_failed(task, StandardError.new("delivery failed"))

      expect(task_monitor.registered?(task)).to be true
    end
  end
end
