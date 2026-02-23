# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Rails Engine that makes gem migrations discoverable by the host application.
    class Engine < ::Rails::Engine
      engine_name "patient_http_solid_queue"

      initializer "patient_http_solid_queue.migrations" do
        config.paths["db/migrate"] << File.expand_path("../../../db/migrate", __dir__)
      end
    end
  end
end
