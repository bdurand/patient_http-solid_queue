# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Registers lifecycle hooks with SolidQueue to start/stop the async HTTP processor.
    class LifecycleHooks
      @registered = false

      class << self
        def register
          return if @registered

          ::SolidQueue.on_worker_start { PatientHttp::SolidQueue.start }
          ::SolidQueue.on_worker_stop { PatientHttp::SolidQueue.stop }

          @registered = true
        end
      end
    end
  end
end
