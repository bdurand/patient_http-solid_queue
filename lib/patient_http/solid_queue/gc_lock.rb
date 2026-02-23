# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model for distributed garbage collection locking.
    #
    # Ensures only one process runs orphan detection at a time. The last_gc_at
    # column records when GC was last successfully completed, allowing processes
    # to skip GC attempts if another process ran GC recently.
    class GcLock < Record
      self.table_name = "patient_http_solid_queue_gc_locks"
    end
  end
end
