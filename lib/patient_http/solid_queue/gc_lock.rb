# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model for the distributed garbage collection lock.
    #
    # The lock makes sure that only one process at a time runs orphan
    # detection. The `last_gc_at` column records when garbage collection last
    # completed, so a process can skip it if another process ran it recently.
    class GcLock < Record
      self.table_name = "patient_http_solid_queue_gc_locks"
    end
  end
end
