# frozen_string_literal: true

class StatusReport < ApplicationRecord
  class Callback
    def on_complete(_response)
      StatusReport.increment_complete!("Asynchronous")
    end

    def on_error(_error)
      StatusReport.increment_error!("Asynchronous")
    end
  end

  validates :name, presence: true, uniqueness: true

  class << self
    def increment_complete!(name)
      find_or_create_counter(name)
      where(name: name).update_all("complete_count = complete_count + 1")
    end

    def increment_error!(name)
      find_or_create_counter(name)
      where(name: name).update_all("error_count = error_count + 1")
    end

    def reset_counter!(name)
      where(name: name).update_all(complete_count: 0, error_count: 0)
    end

    def status_for(name)
      record = find_by(name: name)
      if record
        {complete: record.complete_count, error: record.error_count}
      else
        {complete: 0, error: 0}
      end
    end

    private

    def find_or_create_counter(name)
      find_or_create_by!(name: name)
    rescue ActiveRecord::RecordNotUnique
      # Race condition on create — the row now exists, which is fine
    end
  end

  def initialize(name_or_attributes = {})
    if name_or_attributes.is_a?(String)
      super(name: name_or_attributes)
    else
      super
    end
  end

  def complete!
    self.class.increment_complete!(name)
  end

  def error!
    self.class.increment_error!(name)
  end

  def status
    self.class.status_for(name)
  end

  def reset!
    self.class.reset_counter!(name)
  end
end
