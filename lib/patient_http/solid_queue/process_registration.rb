# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model tracking registered async HTTP processor processes.
    #
    # Each record represents a running processor process. The last_seen_at
    # timestamp is updated via heartbeats. Records for processes that are not
    # in this table are considered orphaned during GC.
    class ProcessRegistration < Record
      self.table_name = "patient_http_solid_queue_processes"
    end
  end
end
