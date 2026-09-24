# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Stores the current Active Job for each thread.
    #
    # Code that runs in a job reads the job from this class instead of
    # receiving it as an argument. `RequestJob` uses the job to re-enqueue a
    # request.
    class Context
      @jobs = Concurrent::Map.new

      class << self
        # Returns the current Active Job for this thread.
        #
        # @return [Hash, nil] The serialized job, or `nil` if no job is set.
        def current_job
          @jobs[Thread.current.object_id]
        end

        # Sets the current job for the duration of a block.
        #
        # @param job_data [Hash] The serialized Active Job.
        # @yield The block to run.
        # @return [Object] The return value of the block.
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
