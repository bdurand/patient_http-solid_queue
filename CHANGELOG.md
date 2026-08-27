# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.2.0

### Added

- Named processors: declare profiles with `config.processor(:llm, max_connections: 200)` and route requests with `PatientHttp::SolidQueue.execute(request, processor: :llm)` or a `processor:` option on the request itself. Each profile runs as an independent processor with its own capacity, timeouts, and threads, so one workload class cannot starve another. The processor name is serialized into the job arguments, so retries and crash recovery keep their routing. A job that names an unconfigured processor raises `PatientHttp::UnknownProcessorError` and is retried, which makes new profile names safe to roll out gradually. Jobs from older gem versions run on the `:default` processor.
- Capacity fast path: requests are rejected with a cheap in-memory capacity check (`Processor#capacity_available?`) before the durable registry record is written, so a full processor rejects without a database insert and delete.
- The `completion_failed` processor event is handled by keeping the crash-recovery registry entry and releasing it from this process, so a request whose result could not be delivered is re-enqueued by the orphan collector on its next pass instead of being silently lost.
- A failure to write the crash-recovery registry entry raises `PatientHttp::SolidQueue::RegistrationError`, which `RequestJob` retries with backoff so a transient database issue does not fail the request outright.

### Changed

- Requests are now registered in the crash-recovery registry when the processor accepts them (`request_enqueued`, on the job worker thread), instead of when they start processing (`request_start`, on the reactor thread). The registry insert no longer blocks the event loop, queued requests are covered by heartbeats, and a failure to write the record rejects the request and raises to the caller so a task is never accepted without a durable record. Rejected and re-enqueued tasks now remove their registry entries, closing a duplicate-delivery window after process restarts.
- With patient_http 1.5.0, result delivery (response decoding, callback job enqueueing, registry cleanup) runs on the processor's completion worker threads instead of the reactor thread. Size the database pool to cover `completion_threads` plus the monitor thread.
- TaskMonitor operations check out a database connection only for the duration of each operation, so gem-owned threads do not pin connections from the pool.
- The task monitor thread is now owned by the module and shared across all processors; `ProcessorObserver.new` takes a `task_monitor:` keyword argument.
- The `patient_http` dependency floor is now 1.5.0.

## 1.1.0

### Changed

- `PatientHttp::SolidQueue.configure` now sets the built configuration as the `PatientHttp.default_configuration` so that secrets registered at the module level with `PatientHttp.register_secret` are applied to the configuration the processor runs with, regardless of boot order. This requires patient_http 1.3.0 or newer.

## 1.0.2

### Fixed

- Externally stored request payloads are no longer deleted as soon as the request is submitted to the processor. They are now retained until the request completes so that Active Job retries, shutdown re-enqueues, and crash recovery can still fetch them. Discarded `RequestJob` jobs clean up their stored payloads via an `after_discard` hook.
- `RequestJob` now declares `retry_on` for `PatientHttp::MaxCapacityError` and `PatientHttp::NotRunningError` with a polynomial backoff. Previously these errors (raised as normal backpressure when the processor is at max capacity) sent jobs straight to the failed jobs list because Active Job does not retry by default.
- `CallbackJob` no longer deletes externally stored payloads when the callback raises, so retries can fetch the payload and re-run the callback.
- Crash recovery no longer silently loses a request if the process crashes between removing the inflight record and re-enqueueing the job. The record is now claimed first and only deleted after the job has been enqueued, so a failed recovery attempt is retried by a later garbage collection pass.
- Fixed process registration and garbage collection on MySQL, where passing an explicit conflict target to `upsert`/`insert_all` raises an error. Crash recovery was silently disabled on MySQL.
- `PatientHttp::SolidQueue.configure` and `reset_configuration!` now reset the memoized external storage so it picks up the new configuration.
- Fixed race conditions that could create duplicate processors or task monitor threads from concurrent lifecycle calls; starting while the processor is draining no longer replaces it.
- The task monitor thread no longer holds a database connection from the pool while sleeping between heartbeats.

## 1.0.1

### Fixed

- Ensure `PatientHttp::SolidQueue` is automatically registered as the HTTP processor on a process not running the SolidQueue server. This gem will now auto register itself on a client process either by calling `PatientHttp::SolidQueue.configure` or `PatientHttp::SolidQueue.register_handler` directly.

## 1.0.0

### Added

- Dedicated async HTTP processor integration for Solid Queue to avoid blocking worker threads during in-flight requests.
- `PatientHttp::SolidQueue` API with convenience methods for common HTTP verbs (`get`, `post`, `put`, `patch`, and `delete`).
- Callback-based completion and error handling via `on_complete` and `on_error`, executed through Active Job via `PatientHttp::SolidQueue::CallbackJob`.
- Support for callback context via `callback_args`, available from response and error objects.
- Automatic processor lifecycle integration with `SolidQueue.on_worker_start` and `SolidQueue.on_worker_stop` hooks.
- Database-backed in-flight request tracking with heartbeat updates, orphan detection, and automatic re-enqueue of interrupted requests.
