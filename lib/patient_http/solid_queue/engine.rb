# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Rails engine that exposes the gem's migrations to the
    # `patient_http_solid_queue:install:migrations` task. The migrations don't
    # run with the host application's `db:migrate` until they are copied.
    class Engine < ::Rails::Engine
      engine_name "patient_http_solid_queue"

      initializer "patient_http_solid_queue.migrations" do
        config.paths["db/migrate"] << File.expand_path("../../../db/migrate", __dir__)
      end
    end
  end
end
