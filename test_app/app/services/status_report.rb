# frozen_string_literal: true

class StatusReport
  COUNTERS = Hash.new { |hash, key| hash[key] = {complete: 0, error: 0} }
  COUNTERS_MUTEX = Mutex.new

  class Callback
    def on_complete(_response)
      StatusReport.new("Asynchronous").complete!
    end

    def on_error(_error)
      StatusReport.new("Asynchronous").error!
    end
  end

  def initialize(name)
    @name = name
  end

  def complete!
    COUNTERS_MUTEX.synchronize { COUNTERS[@name][:complete] += 1 }
  end

  def error!
    COUNTERS_MUTEX.synchronize { COUNTERS[@name][:error] += 1 }
  end

  def status
    COUNTERS_MUTEX.synchronize { COUNTERS[@name].dup }
  end

  def reset!
    COUNTERS_MUTEX.synchronize do
      COUNTERS[@name][:complete] = 0
      COUNTERS[@name][:error] = 0
    end
  end
end
