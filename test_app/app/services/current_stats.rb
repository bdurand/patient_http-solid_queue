# frozen_string_literal: true

class CurrentStats
  attr_reader :inflight

  def initialize
    @inflight = PatientHttp::SolidQueue.processor&.inflight_count.to_i
  end

  def to_h
    {inflight: inflight}
  end
end
