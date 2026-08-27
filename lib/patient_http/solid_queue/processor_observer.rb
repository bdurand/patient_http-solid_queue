# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Processor observer that maintains the crash-recovery registry for one
    # processor. The task monitor is shared across all processors in the
    # process; the module owns it and the monitor thread.
    #
    # Tasks are registered in the crash-recovery registry when the processor
    # accepts them, before Processor#enqueue returns, so a request always has
    # a durable record from the moment the caller hands it off. Registration
    # runs on the caller's thread (a job worker thread), not the reactor
    # thread. The entry is removed when the request completes or when an
    # Active Job owns the request again (the task was rejected or
    # re-enqueued). When result delivery fails (completion_failed), the entry
    # is deliberately kept so the orphan collector re-enqueues the request
    # instead of losing it.
    class ProcessorObserver < PatientHttp::ProcessorObserver
      attr_reader :task_monitor

      def initialize(processor, task_monitor:)
        @processor = processor
        @task_monitor = task_monitor
        @requeued_task_ids = Set.new
        @requeued_mutex = Mutex.new
      end

      def request_enqueued(request_task)
        task_monitor.register(request_task)
      end

      def request_rejected(request_task)
        task_monitor.unregister(request_task)
      end

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

      def request_end(request_task)
        requeued = @requeued_mutex.synchronize { @requeued_task_ids.delete?(request_task.id) }
        return if requeued

        task_monitor.unregister(request_task)
      end

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
