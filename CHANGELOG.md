# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0

### Added

- Dedicated async HTTP processor integration for Solid Queue to avoid blocking worker threads during in-flight requests.
- `PatientHttp::SolidQueue` API with convenience methods for common HTTP verbs (`get`, `post`, `put`, `patch`, and `delete`).
- Callback-based completion and error handling via `on_complete` and `on_error`, executed through Active Job via `PatientHttp::SolidQueue::CallbackJob`.
- Support for callback context via `callback_args`, available from response and error objects.
- Automatic processor lifecycle integration with `SolidQueue.on_worker_start` and `SolidQueue.on_worker_stop` hooks.
- Database-backed in-flight request tracking with heartbeat updates, orphan detection, and automatic re-enqueue of interrupted requests.
