# frozen_string_literal: true

# Lookups for the processor profiles declared in the initializer so the form,
# the stats, and the request routing all agree on which processors exist.
module ProcessorProfiles
  class << self
    # All configured processor names, with :default first.
    def names
      PatientHttp::SolidQueue.configuration.processor_profiles.keys
    end

    def max_connections(name)
      PatientHttp::SolidQueue.configuration.processor_config(name).max_connections
    end

    # Requests go to the default processor unless the value names one of the
    # configured profiles.
    def resolve(value)
      name = value.to_s.to_sym
      names.include?(name) ? name : :default
    end
  end
end
