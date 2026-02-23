# frozen_string_literal: true

module PatientHttp
  module SolidQueue
    # Processor Observer that monitors for crashed processes in order to
    # re-enqueue workers, and manages the TaskMonitor lifecycle.
    class ProcessorObserver < PatientHttp::ProcessorObserver
      attr_reader :task_monitor

      def initialize(processor)
        @processor = processor
        @task_monitor = TaskMonitor.new(processor.config)
        @monitor_thread = TaskMonitorThread.new(
          processor.config,
          @task_monitor,
          -> { @processor.inflight_request_ids }
        )
      end

      def start
        @monitor_thread.start
      end

      def stop
        @monitor_thread.stop
        task_monitor.remove_process
      end

      def request_start(request_task)
        task_monitor.register(request_task)
      end

      def request_end(request_task)
        task_monitor.unregister(request_task)
      end
    end
  end
end
