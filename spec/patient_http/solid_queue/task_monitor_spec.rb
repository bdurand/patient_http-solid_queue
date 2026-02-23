# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::TaskMonitor do
  let(:config) { PatientHttp::SolidQueue::Configuration.new }
  subject(:monitor) { described_class.new(config) }

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

  describe "#register and #unregister" do
    it "creates and removes an InflightRequest record" do
      monitor.register(request_task)
      expect(monitor.registered?(request_task)).to be true

      monitor.unregister(request_task)
      expect(monitor.registered?(request_task)).to be false
    end
  end

  describe "#ping_process and #remove_process" do
    it "creates and removes a ProcessRegistration record" do
      expect {
        monitor.ping_process
      }.to change(PatientHttp::SolidQueue::ProcessRegistration, :count).by(1)

      expect {
        monitor.remove_process
      }.to change(PatientHttp::SolidQueue::ProcessRegistration, :count).by(-1)
    end
  end

  describe "#update_heartbeats" do
    it "updates heartbeat_at for registered tasks" do
      monitor.register(request_task)
      original = PatientHttp::SolidQueue::InflightRequest.first.heartbeat_at

      sleep 0.01
      monitor.update_heartbeats([request_task.id])

      updated = PatientHttp::SolidQueue::InflightRequest.first.heartbeat_at
      expect(updated).to be > original
    end
  end

  describe "#acquire_gc_lock and #release_gc_lock" do
    it "acquires and releases the lock" do
      expect(monitor.acquire_gc_lock).to be true
      monitor.release_gc_lock
    end

    it "returns false if lock is already held" do
      monitor.acquire_gc_lock
      other_monitor = described_class.new(config)
      expect(other_monitor.acquire_gc_lock).to be false
      monitor.release_gc_lock
    end

    it "uses a single semaphore row across processes" do
      monitor.acquire_gc_lock
      other_monitor = described_class.new(config)
      other_monitor.acquire_gc_lock

      expect(PatientHttp::SolidQueue::GcLock.count).to eq(1)

      monitor.release_gc_lock
      expect(PatientHttp::SolidQueue::GcLock.count).to eq(1)
    end

    it "updates last_gc_at on release" do
      monitor.acquire_gc_lock
      monitor.release_gc_lock
      lock = PatientHttp::SolidQueue::GcLock.first
      expect(lock.last_gc_at).not_to be_nil
    end

    it "skips acquiring if GC was run recently" do
      monitor.acquire_gc_lock
      monitor.release_gc_lock

      other = described_class.new(config)
      expect(other.acquire_gc_lock).to be false
    end
  end

  describe "#cleanup_orphaned_requests" do
    it "re-enqueues requests from dead processes" do
      monitor.register(request_task)

      # Set heartbeat far in the past (don't register process)
      PatientHttp::SolidQueue::InflightRequest.update_all(heartbeat_at: Time.current - 1000.seconds)

      count = monitor.cleanup_orphaned_requests(config.orphan_threshold, nil)
      expect(count).to eq(1)
    end

    it "skips requests from live processes" do
      monitor.ping_process
      monitor.register(request_task)
      PatientHttp::SolidQueue::InflightRequest.update_all(heartbeat_at: Time.current - 1000.seconds)

      count = monitor.cleanup_orphaned_requests(config.orphan_threshold, nil)
      expect(count).to eq(0)
    end

    it "re-enqueues requests from stale process registrations" do
      monitor.ping_process
      monitor.register(request_task)

      stale_time = Time.current - (config.orphan_threshold + 1).seconds
      PatientHttp::SolidQueue::ProcessRegistration.update_all(last_seen_at: stale_time)
      PatientHttp::SolidQueue::InflightRequest.update_all(heartbeat_at: stale_time)

      count = monitor.cleanup_orphaned_requests(config.orphan_threshold, nil)
      expect(count).to eq(1)
    end

    it "prunes stale process registrations during cleanup" do
      monitor.ping_process

      stale_time = Time.current - (config.orphan_threshold + 1).seconds
      PatientHttp::SolidQueue::ProcessRegistration.update_all(last_seen_at: stale_time)

      expect {
        monitor.cleanup_orphaned_requests(config.orphan_threshold, nil)
      }.to change(PatientHttp::SolidQueue::ProcessRegistration, :count).by(-1)
    end
  end

  describe ".clear_all!" do
    it "clears all tables in test mode" do
      monitor.register(request_task)
      monitor.ping_process
      monitor.acquire_gc_lock

      described_class.clear_all!

      expect(PatientHttp::SolidQueue::InflightRequest.count).to eq(0)
      expect(PatientHttp::SolidQueue::ProcessRegistration.count).to eq(0)
      expect(PatientHttp::SolidQueue::GcLock.count).to eq(0)
    end
  end
end
