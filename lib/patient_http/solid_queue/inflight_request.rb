# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model tracking inflight HTTP requests for crash recovery.
    #
    # Each record represents a single in-flight HTTP request. The heartbeat_at
    # timestamp is updated periodically; stale records from dead processes are
    # detected and re-enqueued by the GC mechanism.
    class InflightRequest < Record
      self.table_name = "patient_http_solid_queue_inflight_requests"
    end
  end
end
