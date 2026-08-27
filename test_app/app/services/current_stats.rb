# frozen_string_literal: true

class CurrentStats
  attr_reader :inflight, :processors

  def initialize
    @processors = processor_counts
    @inflight = @processors.values.sum { |counts| counts[:inflight] }
  end

  def to_h
    {inflight: inflight, processors: processors}
  end

  private

  # Inflight and capacity counts for each configured processor.
  def processor_counts
    ProcessorProfiles.names.each_with_object({}) do |name, counts|
      processor = PatientHttp::SolidQueue.processor(name)
      counts[name] = {
        inflight: processor&.total_count.to_i,
        max_capacity: processor ? processor.config.max_connections : 0
      }
    end
  end
end
