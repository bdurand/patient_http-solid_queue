# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Thread-safe store for the Active Job that the current thread is running.
    #
    # The store is keyed by thread ID, so async HTTP requests can read the job
    # data without passing it explicitly. `RequestJob` uses this context to
    # re-enqueue jobs.
    class Context
      @jobs = Concurrent::Map.new

      class << self
        # Returns the job data for the current thread.
        #
        # @return [Hash, nil] The serialized Active Job, or `nil` if the thread
        #   isn't running a job.
        def current_job
          @jobs[Thread.current.object_id]
        end

        # Sets the job data for the current thread while a block runs.
        #
        # @param job_data [Hash] The serialized Active Job.
        # @yield Runs with the job data set.
        # @return [Object] The block's return value.
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
