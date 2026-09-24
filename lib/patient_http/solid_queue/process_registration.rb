# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model that tracks processes running the processors.
    #
    # Each record represents one running process. Heartbeats update the
    # +last_seen_at+ timestamp. During garbage collection, in-flight requests
    # from processes that aren't in this table count as orphaned.
    class ProcessRegistration < Record
      self.table_name = "patient_http_solid_queue_processes"
    end
  end
end
