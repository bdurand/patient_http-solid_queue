# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model for the distributed garbage collection lock.
    #
    # Ensures that only one process runs orphan detection at a time. The
    # +last_gc_at+ column records when garbage collection last finished, so
    # processes can skip garbage collection if another process ran it recently.
    class GcLock < Record
      self.table_name = "patient_http_solid_queue_gc_locks"
    end
  end
end
