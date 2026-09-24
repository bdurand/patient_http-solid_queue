# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Processor observer that maintains the crash-recovery registry for one
    # processor. All processors in the process share one task monitor. The
    # +PatientHttp::SolidQueue+ module owns the task monitor and the monitor
    # thread.
    #
    # The observer registers a task when the processor accepts it, before
    # +Processor#enqueue+ returns. A request has a durable record from the
    # moment the caller hands it off. Registration runs on the caller's thread,
    # which is a job worker thread, not the reactor thread.
    #
    # The observer removes the record when the request completes, or when an
    # Active Job owns the request again because the task was rejected or
    # re-enqueued. If result delivery fails, the observer keeps the record so
    # the orphan collector re-enqueues the request instead of losing it.
    class ProcessorObserver < PatientHttp::ProcessorObserver
      # @return [TaskMonitor] The shared crash-recovery registry.
      attr_reader :task_monitor

      # Creates an observer for a processor.
      #
      # @param processor [PatientHttp::Processor] The processor to observe.
      # @param task_monitor [TaskMonitor] The shared crash-recovery registry.
      def initialize(processor, task_monitor:)
        @processor = processor
        @task_monitor = task_monitor
        @requeued_task_ids = Set.new
        @requeued_mutex = Mutex.new
      end

      # Registers the task in the crash-recovery registry.
      #
      # @param request_task [PatientHttp::RequestTask] The accepted task.
      # @return [void]
      # @raise [RegistrationError] If the record can't be written.
      def request_enqueued(request_task)
        task_monitor.register(request_task)
      end

      # Removes a rejected task from the crash-recovery registry.
      #
      # @param request_task [PatientHttp::RequestTask] The rejected task.
      # @return [void]
      def request_rejected(request_task)
        task_monitor.unregister(request_task)
      end

      # Removes a re-enqueued task from the crash-recovery registry.
      #
      # @param request_task [PatientHttp::RequestTask] The re-enqueued task.
      # @return [void]
      def request_requeued(request_task)
        task_monitor.unregister(request_task)
        # The re-enqueue path fires request_end after request_requeued, but
        # only for tasks that already started. Remember those tasks so that
        # request_end does not unregister a second time. A task that never
        # started gets no request_end, so remembering it would leak the id
        # forever.
        return unless request_task.started?

        @requeued_mutex.synchronize { @requeued_task_ids << request_task.id }
      end

      # Removes a finished task from the crash-recovery registry, unless
      # {#request_requeued} already removed it.
      #
      # @param request_task [PatientHttp::RequestTask] The finished task.
      # @return [void]
      def request_end(request_task)
        requeued = @requeued_mutex.synchronize { @requeued_task_ids.delete?(request_task.id) }
        return if requeued

        task_monitor.unregister(request_task)
      end

      # Releases the task's crash-recovery record so the orphan collector
      # re-enqueues the request, and logs the error.
      #
      # @param request_task [PatientHttp::RequestTask] The task whose result
      #   couldn't be delivered.
      # @param error [Exception] The delivery error.
      # @return [void]
      def completion_failed(request_task, error)
        # Keep the crash-recovery registry entry, but hand it off to the orphan
        # collector. Orphan collection ignores records that belong to a live
        # process, so the entry has to be released for the request to be
        # re-enqueued on the next pass rather than on the next process restart.
        task_monitor.release(request_task)

        PatientHttp::SolidQueue.configuration.logger&.error(
          "[PatientHttp::SolidQueue] Result delivery failed for request #{request_task.id}; " \
          "leaving crash-recovery record for re-enqueue: #{error.class} - #{error.message}"
        )
      end
    end
  end
end
