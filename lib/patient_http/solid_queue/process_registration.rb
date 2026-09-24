# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model for processes that run an async HTTP processor.
    #
    # Each record represents a running process. Heartbeats update the
    # `last_seen_at` timestamp. During garbage collection, in-flight requests
    # from processes that aren't in this table are considered orphaned.
    class ProcessRegistration < Record
      self.table_name = "patient_http_solid_queue_processes"
    end
  end
end
