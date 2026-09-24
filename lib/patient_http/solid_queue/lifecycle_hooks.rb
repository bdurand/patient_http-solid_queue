# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Registers Solid Queue worker lifecycle hooks that manage the processors.
    #
    # The hooks do the following:
    #
    # - Start the processors when a Solid Queue worker starts
    #   (`on_worker_start`).
    # - Stop the processors when the worker stops (`on_worker_stop`).
    class LifecycleHooks
      @registered = false

      class << self
        # Registers the lifecycle hooks. The gem calls this method when it loads.
        # Repeated calls have no effect.
        #
        # @return [void]
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
