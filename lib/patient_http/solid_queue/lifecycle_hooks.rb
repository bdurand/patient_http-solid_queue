# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Registers Solid Queue lifecycle hooks that start and stop the processors.
    class LifecycleHooks
      @registered = false

      class << self
        # Registers the worker start and stop hooks with Solid Queue. Calling
        # this method more than once has no effect.
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
