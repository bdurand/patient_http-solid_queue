# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Base Active Record class for patient_http-solid_queue models.
    class Record < ::SolidQueue::Record
      self.abstract_class = true
    end
  end
end
