# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SolidQueue::LifecycleHooks do
  it "only registers once" do
    # Already registered at load time; calling register again should be a no-op
    initial_count = SolidQueue.instance_variable_get(:@worker_start_callbacks)&.size || 0
    described_class.register
    new_count = SolidQueue.instance_variable_get(:@worker_start_callbacks)&.size || 0
    expect(new_count).to eq(initial_count)
  end
end
