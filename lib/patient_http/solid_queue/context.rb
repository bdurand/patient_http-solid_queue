# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Provides thread-safe context for Active Jobs.
    #
    # Manages the current Active Job context using a thread-id keyed hash,
    # allowing async HTTP requests to access job information without it being
    # passed explicitly. Only RequestJob needs this context for re-enqueueing jobs.
    class Context
      @jobs = Concurrent::Map.new

      class << self
        # Returns the current job data hash for the running thread.
        #
        # @return [Hash, nil]
        def current_job
          @jobs[Thread.current.object_id]
        end

        # Set the current job context for the duration of a block.
        #
        # @param job_data [Hash] Active Job serialized hash
        # @yield
        def with_job(job_data)
          thread_id = Thread.current.object_id
          previous_job = @jobs[thread_id]
          @jobs[thread_id] = job_data
          yield
        ensure
          previous_job ? @jobs[thread_id] = previous_job : @jobs.delete(thread_id)
        end
      end
    end
  end
end
