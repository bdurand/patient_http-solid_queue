# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
