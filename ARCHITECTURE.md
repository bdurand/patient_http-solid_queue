# Architecture

## Overview

PatientHttp::SolidQueue provides a Solid Queue integration layer for the [patient_http](https://github.com/bdurand/patient_http) gem, enabling long-running HTTP requests to be offloaded from worker execution to a dedicated async I/O processor. This integration uses Active Job for request enqueueing and callback invocation, while leveraging patient_http's Fiber-based concurrency to handle many concurrent HTTP requests without blocking worker threads.

## Key Design Principles

1. **Non-blocking workers**: Jobs enqueue HTTP requests and quickly return so worker capacity remains available
2. **Singleton processor per process**: One async I/O processor per worker process handles request concurrency
3. **Callback service pattern**: HTTP results are delivered to callback services via `on_complete` and `on_error`
4. **Lifecycle integration**: Processor lifecycle is tied to Solid Queue worker start/stop hooks
5. **Active Job-native task handling**: Request execution, callback jobs, and retries use Active Job semantics

## Core Components

### PatientHttp::Processor (from patient_http)
A dedicated processor thread that runs an async fiber reactor and manages concurrent HTTP execution.

### PatientHttp::SolidQueue::RequestJob
Active Job entry point for async requests. It:
- receives serialized request payloads
- decrypts and loads request data
- submits the request to `RequestExecutor`

### PatientHttp::SolidQueue::TaskHandler
Implements patient_http task handling for Active Job integration. It:
- enqueues `CallbackJob` on completion/error
- retries original jobs via `ActiveJob::Base.deserialize(...).enqueue`
- stores large payloads using external storage when configured

### PatientHttp::SolidQueue::CallbackJob
Active Job that resolves the callback class and invokes:
- `on_complete(response)` for successful requests
- `on_error(error)` for request errors

### PatientHttp::SolidQueue::SolidQueueLifecycleHooks
Registers hooks to automatically:
- start processor on `SolidQueue.on_worker_start`
- stop processor on `SolidQueue.on_worker_stop`

### PatientHttp::SolidQueue::ProcessorObserver
Observes processor task lifecycle and updates task monitor records.

### PatientHttp::SolidQueue::TaskMonitor
Tracks in-flight requests in database tables and performs orphan recovery. It:
- records request heartbeats
- tracks active processes
- re-enqueues orphaned requests from stale processes

### PatientHttp::SolidQueue::TaskMonitorThread
Background thread that periodically:
- updates in-flight heartbeats
- pings process registration
- runs orphan cleanup under a distributed DB lock

### Configuration
`PatientHttp::SolidQueue::Configuration` wraps patient_http configuration and adds Solid Queue-specific options such as:
- `queue_name`
- `heartbeat_interval`
- `orphan_threshold`
- `payload_store_threshold`
- `encryption` / `decryption`

## Request Lifecycle

1. Application code calls `PatientHttp::SolidQueue.get/post/put/patch/delete`.
2. `RequestJob` is enqueued with serialized request data and callback metadata.
3. `RequestJob` decrypts/deserializes and calls `RequestExecutor.execute`.
4. `RequestExecutor` creates an async task and enqueues it on the processor.
5. Processor executes HTTP request asynchronously.
6. `TaskHandler` enqueues `CallbackJob` with serialized response/error.
7. `CallbackJob` invokes the callback service method.

## Process Model

Each worker process runs:
- worker threads for regular Active Job execution
- one async HTTP processor thread
- one task monitor thread for heartbeat and orphan recovery

## State Management

Processor lifecycle states are managed by patient_http and exposed via:
- `PatientHttp::SolidQueue.running?`
- `PatientHttp::SolidQueue.draining?`
- `PatientHttp::SolidQueue.stopping?`
- `PatientHttp::SolidQueue.stopped?`

On shutdown, the processor waits up to `shutdown_timeout` for in-flight requests before interrupting remaining tasks.

## Crash Recovery

Crash recovery is database-backed:

- In-flight requests are stored in `patient_http_solid_queue_inflight_requests`
- Active processes are tracked in `patient_http_solid_queue_processes`
- Distributed GC/orphan cleanup coordination uses `patient_http_solid_queue_gc_locks`

Recovery flow:
1. A request is registered with process ID + heartbeat timestamp
2. Heartbeats are updated while request remains in-flight
3. If a process stops heartbeating past `orphan_threshold`, another process can reclaim the request
4. The original Active Job is re-enqueued with executions reset

## Monitoring Hooks

Instrumentation hooks are available globally:
- `PatientHttp::SolidQueue.after_completion { |response| ... }`
- `PatientHttp::SolidQueue.after_error { |error| ... }`

These callbacks support metrics pipelines (StatsD, Prometheus adapters, etc.) and error reporting integrations.

## Testing Behavior

In test mode (`PatientHttp.testing?`), request execution runs synchronously to make specs deterministic while keeping the same public API.

## Further Reading

- [README](README.md)
