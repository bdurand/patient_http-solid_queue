# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Active Record model for in-flight HTTP requests, used for crash recovery.
    #
    # Each record represents one in-flight HTTP request. The processor updates
    # the `heartbeat_at` timestamp periodically. Garbage collection finds stale
    # records from dead processes and re-enqueues their requests.
    class InflightRequest < Record
      self.table_name = "patient_http_solid_queue_inflight_requests"
    end
  end
end
