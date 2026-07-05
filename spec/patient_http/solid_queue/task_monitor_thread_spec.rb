# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::TaskMonitorThread do
  let(:config) { PatientHttp::SolidQueue::Configuration.new(heartbeat_interval: 1) }
  let(:task_monitor) { instance_double(PatientHttp::SolidQueue::TaskMonitor) }

  before do
    allow(task_monitor).to receive(:ping_process)
    allow(task_monitor).to receive(:update_heartbeats)
    allow(task_monitor).to receive(:acquire_gc_lock).and_return(false)
    allow(task_monitor).to receive(:release_gc_lock)
    allow(task_monitor).to receive(:cleanup_orphaned_requests).and_return(0)
    allow(task_monitor).to receive(:remove_process)
  end

  subject(:thread) { described_class.new(config, task_monitor, -> { [] }) }

  describe "#start and #stop" do
    it "transitions from not running to running" do
      expect(thread.running?).to be false
      thread.start
      expect(thread.running?).to be true
      thread.stop
    end

    it "pings the process on start" do
      expect(task_monitor).to receive(:ping_process).at_least(:once)
      thread.start
      thread.stop
    end

    it "is idempotent when starting twice" do
      thread.start
      thread.start
      expect(thread.running?).to be true
      thread.stop
    end

    it "does not start a second thread when already running" do
      thread.start
      first_thread = thread.instance_variable_get(:@thread)

      thread.start

      expect(thread.instance_variable_get(:@thread)).to be(first_thread)
      thread.stop
    end

    it "checks out a database connection only for the duration of the work" do
      pool = PatientHttp::SolidQueue::Record.connection_pool
      allow(pool).to receive(:with_connection).and_call_original

      thread.start
      thread.stop

      expect(pool).to have_received(:with_connection).at_least(:once)
    end
  end
end
