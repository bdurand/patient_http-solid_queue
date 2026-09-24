# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Base Active Record class for this gem's models. The models use the
    # Solid Queue database.
    class Record < ::SolidQueue::Record
      self.abstract_class = true
    end
  end
end
