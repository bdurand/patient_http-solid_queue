# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Base Active Record class for the gem's models. Uses the Solid Queue
    # database.
    class Record < ::SolidQueue::Record
      self.abstract_class = true
    end
  end
end
