# PatientHttp::SolidQueue

[![Continuous Integration](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http-solid_queue.svg)](https://badge.fury.io/rb/patient_http-solid_queue)

*Built for APIs that like to think.*

This gem moves HTTP requests out of Solid Queue jobs and into a dedicated asynchronous I/O processor that runs in the Solid Queue worker process. It's built on the [patient_http gem](https://github.com/bdurand/patient_http). Worker threads don't wait for HTTP responses, so they can process other jobs while requests are in flight.

## Motivation

Solid Queue assumes that jobs are short-lived. A long-running HTTP request blocks its worker thread, so other jobs wait, latency rises, and throughput drops. LLM and other AI APIs make this worse because a single request can take many seconds.

Without this gem, each HTTP request holds a worker thread until the response arrives:

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Traditional Solid Queue Job                         │
│                                                                        │
│  Worker Thread 1: [████████████ HTTP Request (5s) ████████████████]    │
│  Worker Thread 2: [████████████ HTTP Request (5s) ████████████████]    │
│  Worker Thread 3: [████████████ HTTP Request (5s) ████████████████]    │
│                                                                        │
│  → 3 workers blocked for 5 seconds = 0 jobs processed                  │
└────────────────────────────────────────────────────────────────────────┘
```

With this gem, the worker thread hands the request to the processor and moves on:

```
┌────────────────────────────────────────────────────────────────────────┐
│                     With Async HTTP Processor                          │
│                                                                        │
│  Worker Thread 1: [█ Enqueue █][█ Job █][█ Job █][█ Job █][█ Job █]    │
│  Worker Thread 2: [█ Enqueue █][█ Job █][█ Job █][█ Job █][█ Job █]    │
│  Worker Thread 3: [█ Enqueue █][█ Job █][█ Job █][█ Job █][█ Job █]    │
│                                                                        │
│  Async Processor: [═══════════ 100+ concurrent HTTP requests ════════] │
│                                                                        │
│  → Workers immediately free = dozens of jobs processed                 │
└────────────────────────────────────────────────────────────────────────┘
```

The processor runs in a dedicated thread in the worker process. It uses Ruby fibers to run hundreds of concurrent HTTP requests without blocking. When a request finishes, the gem enqueues a job that calls your callback service.

## Quick start

### 1. Create a callback service

Define a callback service class with `on_complete` and `on_error` methods:

```ruby
class FetchDataCallback
  def on_complete(response)
    user_id = response.callback_args[:user_id]
    if response.success?
      data = response.json
      User.find(user_id).update!(external_data: data)
    else
      Rails.logger.error("HTTP #{response.status} fetching data for user #{user_id}")
    end
  end

  def on_error(error)
    user_id = error.callback_args[:user_id]
    Rails.logger.error("Failed to fetch data for user #{user_id}: #{error.message}")
  end
end
```

### 2. Make HTTP requests

Make HTTP requests from anywhere in your code with `PatientHttp`:

```ruby
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
  callback: FetchDataCallback,
  callback_args: {user_id: user_id}
)
```

### How requests run

The gem enqueues the request as an Active Job. When the job runs, it passes the request to a [patient_http](https://github.com/bdurand/patient_http) processor, which runs it asynchronously. When the request finishes, another Active Job calls your callback's `on_complete` method. If the request raises an error, that job calls `on_error` instead.

For other HTTP methods, use `PatientHttp.post`, `PatientHttp.put`, `PatientHttp.patch`, and `PatientHttp.delete`. For the full API reference, see the [patient_http documentation](https://github.com/bdurand/patient_http).

`response.callback_args` and `error.callback_args` return the values that you passed in the `callback_args` option.

> [!IMPORTANT]
> Don't re-raise errors in `on_error` to retry the request. Re-raising retries only the callback job. To retry the original request, enqueue a new request from `on_error`. Make sure these retries stop if the error persists; otherwise, you can create an infinite retry loop.

Active Job doesn't retry callback jobs by default. To retry failed callbacks before Active Job discards them, configure `retry_on` in an initializer:

```ruby
PatientHttp::SolidQueue::CallbackJob.retry_on StandardError, wait: :polynomially_longer, attempts: 5
```

> [!NOTE]
> Active Job runs `after_discard` hooks for any unhandled exception, not only after configured retries run out. Without `retry_on`, the first callback failure calls the `on_retries_exhausted` handler and deletes any externally stored payload. You can still retry the failed job manually from Mission Control, but that retry fails if the payload was stored externally.

The `on_error` callback runs only when the HTTP request raises an exception, such as a timeout or a connection failure. HTTP error status codes (4xx and 5xx) don't call `on_error` by default. The gem treats them as completed requests and passes them to `on_complete`. To treat HTTP errors as exceptions, see [Handle HTTP error responses](#handle-http-error-responses).

### Handle HTTP error responses

By default, the gem treats HTTP error status codes (4xx and 5xx) as completed responses and passes them to `on_complete`. To check the status, use `response.success?`, `response.client_error?`, or `response.server_error?`:

```ruby
class ApiCallback
  def on_complete(response)
    if response.success?
      process_data(response.json)
    elsif response.client_error?
      handle_client_error(response.status, response.body)
    elsif response.server_error?
      handle_server_error(response.status, response.body)
    end
  end

  def on_error(error)
    Rails.logger.error("Request failed: #{error.message}")
  end
end

PatientHttp.get(
  "https://api.example.com/data/#{id}",
  callback: ApiCallback
)
```

To treat HTTP errors as exceptions, set the `raise_error_responses` option. With this option, non-2xx responses call `on_error` with a `PatientHttp::HttpError`:

```ruby
class ApiCallback
  def on_complete(response)
    # Called only for 2xx responses
    process_data(response.json)
  end

  def on_error(error)
    # Called for exceptions, and for HTTP errors when raise_error_responses is set
    if error.is_a?(PatientHttp::HttpError)
      # The response is available as error.response
      Rails.logger.error("HTTP #{error.status} from #{error.url}: #{error.response.body}")
    else
      # Request errors such as timeouts and connection failures
      Rails.logger.error("Request failed: #{error.message}")
    end
  end
end

PatientHttp.get(
  "https://api.example.com/data/#{id}",
  callback: ApiCallback,
  raise_error_responses: true
)
```

`HttpError` exposes the request and response:

```ruby
def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status              # HTTP status code
    puts error.url                 # Request URL
    puts error.http_method         # HTTP method
    puts error.response.body       # Response body
    puts error.response.headers    # Response headers
    puts error.response.json       # Parsed JSON response body, if the body is JSON
  end
end
```

## Usage

### Make requests

The `PatientHttp` module has a method for each HTTP verb:

```ruby
# GET request
PatientHttp.get("https://api.example.com/users/123",
  callback: MyCallback, callback_args: {user_id: 123})

# POST request with a JSON body
PatientHttp.post("https://api.example.com/users",
  json: {name: "John", email: "john@example.com"},
  callback: MyCallback)

# PUT request
PatientHttp.put("https://api.example.com/users/123",
  json: {name: "Updated Name"},
  callback: MyCallback)

# PATCH request
PatientHttp.patch("https://api.example.com/users/123",
  json: {status: "active"},
  callback: MyCallback)

# DELETE request
PatientHttp.delete("https://api.example.com/users/123",
  callback: MyCallback)
```

These methods accept the following options:

| Option | Description |
| --- | --- |
| `callback:` | Required. The callback service class or its class name. |
| `callback_args:` | A hash of arguments that the callback reads from the response or error. |
| `headers:` | The request headers. |
| `body:` | The request body for POST, PUT, and PATCH requests. |
| `json:` | An object to serialize as the JSON request body. You can't use it with `body:`. |
| `params:` | Query parameters to append to the URL. |
| `timeout:` | The request timeout in seconds. |
| `raise_error_responses:` | If `true`, the gem treats non-2xx responses as errors. |

For more control, build a `PatientHttp::Request` object and pass it to `PatientHttp.execute`:

```ruby
request = PatientHttp::Request.new(:get, "https://api.example.com/users/123",
  headers: {"Authorization" => "Bearer token"},
  params: {include: "profile"},
  timeout: 30
)
PatientHttp.execute(request: request, callback: MyCallback, callback_args: {user_id: 123})
```

For the full `Request` and `Response` API reference, see the [patient_http documentation](https://github.com/bdurand/patient_http).

### Use named processors

By default, all requests share one processor and one `max_connections` limit. If one process handles workloads with different profiles, such as slow LLM calls and fast webhook deliveries, a burst in one workload can use all the capacity that the other one needs. To isolate workloads, define named processor profiles:

```ruby
PatientHttp::SolidQueue.configure do |config|
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)
end
```

Each profile runs as a separate processor with its own capacity, timeouts, and threads. Profile options override the top-level configuration. Profiles share all other settings, including secrets, preprocessors, payload stores, encryption, and the logger. The `:default` processor always exists. To override its options, call `config.processor(:default, ...)`.

To route a request to a processor, use one of the following methods:

```ruby
# Pass the processor option to execute
PatientHttp::SolidQueue.execute(request, callback: MyCallback, processor: :llm)

# Set the processor on the request. The setting survives serialization, retries, and crash recovery.
request = PatientHttp::Request.new(:get, url, processor: :llm)

# Set the processor on a request template
template = PatientHttp::RequestTemplate.new(base_url: url, processor: :llm)
```

The gem stores the processor name in the job arguments, so Active Job retries and crash recovery keep the same routing. If a job names a processor that isn't configured in the process that runs it, the job raises `PatientHttp::UnknownProcessorError` and retries with backoff. This lets you roll out new profile names gradually. Jobs enqueued by older gem versions run on the `:default` processor.

### Use request templates

To send repeated requests to the same API, use `PatientHttp::RequestTemplate` to share configuration:

```ruby
class ApiService
  def initialize
    @template = PatientHttp::RequestTemplate.new(
      base_url: "https://api.example.com",
      headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
      timeout: 60
    )
  end

  def fetch_user(user_id)
    request = @template.get("/users/#{user_id}")
    PatientHttp.execute(
      request: request,
      callback: FetchUserCallback,
      callback_args: {user_id: user_id}
    )
  end

  def update_user(user_id, attributes)
    request = @template.patch("/users/#{user_id}", json: attributes)
    PatientHttp.execute(
      request: request,
      callback: UpdateUserCallback,
      callback_args: {user_id: user_id}
    )
  end
end
```

### Use the RequestHelper module

If a class makes many asynchronous HTTP requests, include `PatientHttp::RequestHelper`. It adds the instance methods `async_get`, `async_post`, `async_put`, `async_patch`, and `async_delete`. To set shared options such as `base_url`, `headers`, and `timeout`, call the `request_template` class method.

You don't need to register a request handler. The gem registers one when you call `PatientHttp::SolidQueue.configure` or when the processor starts. The handler stays registered after the processor stops. If a job submits a request while the worker shuts down, the gem enqueues the request as a job for the next process instead of dropping it.

```ruby
class NotificationService
  include PatientHttp::RequestHelper

  request_template base_url: "https://api.example.com",
                   headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
                   timeout: 30

  def notify_user(user_id, message)
    async_post("/notifications",
      json: {user_id: user_id, message: message},
      callback: NotificationCallback,
      callback_args: {user_id: user_id}
    )
  end

  def fetch_user(user_id)
    async_get("/users/#{user_id}",
      callback: FetchUserCallback,
      callback_args: {user_id: user_id}
    )
  end
end
```

The `async_*` methods accept the same options as `PatientHttp.get` and the other request methods. Paths resolve relative to the `base_url` in the request template.

For the full `RequestHelper` documentation, see the [patient_http gem](https://github.com/bdurand/patient_http).

### Pass callback arguments

To pass custom data to your callbacks, use the `callback_args` option:

```ruby
class FetchDataCallback
  def on_complete(response)
    # Read callback_args with symbol or string keys
    user_id = response.callback_args[:user_id]
    request_timestamp = response.callback_args[:request_timestamp]

    User.find(user_id).update!(
      external_data: response.json,
      fetched_at: request_timestamp
    )
  end

  def on_error(error)
    user_id = error.callback_args[:user_id]
    request_timestamp = error.callback_args[:request_timestamp]

    Rails.logger.error(
      "Failed to fetch data for user #{user_id} at #{request_timestamp}: #{error.message}"
    )
  end
end

# Pass data in the callback_args option
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  callback: FetchDataCallback,
  callback_args: {
    user_id: user_id,
    request_timestamp: Time.now.iso8601
  }
)
```

The `callback_args` option follows these rules:

- It must be a hash, or respond to `to_h`, and contain only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, or `Hash`.
- The gem converts hash keys to strings for serialization. This includes keys in nested hashes and in hashes inside arrays.
- You can read values with symbol or string keys, such as `callback_args[:user_id]` or `callback_args["user_id"]`.

### Protect sensitive data

To run callbacks, the gem stores request and response data in your queue backend, and optionally in external storage. The gem stores this data as plain text unless you turn on encryption.

The parent patient_http gem provides encryption. Set `encryption_key` to encrypt and decrypt request and response data with `ActiveSupport::MessageEncryptor`:

```ruby
PatientHttp::SolidQueue.configure do |config|
  config.encryption_key = Rails.application.credentials.patient_http_secret
end
```

For all encryption options, including key rotation and custom encryption callables, see the [patient_http gem](https://github.com/bdurand/patient_http).

## Configuration

Configure the gem in an initializer:

```ruby
PatientHttp::SolidQueue.configure do |config|
  # Maximum number of concurrent HTTP requests (default: 256)
  config.max_connections = 256

  # Default timeout for HTTP requests in seconds (default: 60)
  config.request_timeout = 60

  # Maximum number of host clients to pool (default: 100)
  config.connection_pool_size = 100

  # Connection timeout in seconds (default: nil, which uses request_timeout)
  config.connection_timeout = 10

  # Number of retries for failed requests (default: 3)
  config.retries = 3

  # Handler called when an error callback job exhausts its retries
  config.on_retries_exhausted { |error| MyAlertService.notify(error) }

  # HTTP or HTTPS proxy URL (default: nil)
  # Supports authentication: "http://user:pass@proxy.example.com:8080"
  config.proxy_url = "http://proxy.example.com:8080"

  # Default User-Agent header for all requests (default: "SolidQueue-AsyncHttp")
  config.user_agent = "MyApp/1.0"

  # Timeout for graceful shutdown in seconds
  # (default: SolidQueue.shutdown_timeout - 2)
  # Set this lower than your worker shutdown timeout.
  config.shutdown_timeout = 23

  # Maximum response body size in bytes (default: 1 MB)
  # Larger responses raise ResponseTooLargeError.
  config.max_response_size = 1024 * 1024

  # Maximum number of redirects to follow (default: 5; 0 disables redirects)
  config.max_redirects = 5

  # Whether to raise HttpError for non-2xx responses by default (default: false)
  config.raise_error_responses = false

  # Heartbeat interval for crash recovery in seconds (default: 60)
  config.heartbeat_interval = 60

  # Orphan detection threshold in seconds (default: 300)
  # Requests with no heartbeat for this long are re-enqueued.
  config.orphan_threshold = 300

  # Size threshold in bytes for external payload storage (default: 64 KB)
  # Larger payloads are stored externally if a payload store is configured.
  config.payload_store_threshold = 64 * 1024

  # Queue name for RequestJob and CallbackJob (default: nil, which uses the Active Job default)
  config.queue_name = "async_http"

  # Number of threads that decode responses and deliver results (default: 2)
  config.completion_threads = 2

  # Maximum number of connections per host (default: nil, which means no limit)
  config.max_connections_per_host = 32

  # Named processor profiles for workload isolation (see "Use named processors")
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)

  # Logger (default: SolidQueue.logger)
  config.logger = Rails.logger

  # Encryption key for sensitive data (see "Protect sensitive data")
  # Accepts a string, or an array of strings for key rotation.
  # The parent patient_http gem provides encryption.
  config.encryption_key = Rails.application.credentials.patient_http_secret
end
```

For all options, see the [Configuration](lib/patient_http/solid_queue/configuration.rb) class.

### Tuning

- `max_connections`: Set this based on your system's resources. Each connection uses memory and a file descriptor. A tuned system with enough resources can handle thousands of concurrent connections.
- `request_timeout`: Set this based on the expected response times of the APIs you call. AI APIs can take minutes to respond while they generate content.
- `connection_pool_size`: Controls how many connections to different hosts stay open. Increase it if your application calls many different hosts.
- `connection_timeout`: Set this to fail fast when a connection can't be established. This helps you detect network issues quickly.
- `retries`: The number of times to retry a failed request before the gem calls the error callback.
- `max_response_size`: Limits the size of HTTP responses to prevent excess memory use from unexpectedly large responses. The gem serializes responses as Active Job arguments, and large arguments can cause performance issues. The gem compresses text response bodies. Binary bodies are Base64-encoded, which increases their size by about 33%.
- `payload_store_threshold`: Lower this if your queue backend has trouble with large payloads. Higher values avoid extra reads and writes to external storage.
- `max_connections_per_host`: Limits the number of sockets per host. Make sure the process file descriptor limit covers `max_connections`, plus idle pooled host connections, plus your application's own connections. Raise the limit if needed.
- `completion_threads`: The number of threads that decode responses and deliver results. The default is 2. Increase it if result delivery does heavy work and completions back up. Size the Active Record connection pool to cover the worker threads, these threads, and the task monitor thread.
- `shutdown_timeout`: Must be less than the process supervisor's termination window so that the drain finishes before a forced kill. The default is based on Solid Queue's shutdown timeout. If your supervisor has its own stop timeout, check that too.
- `heartbeat_interval` and `orphan_threshold`: For high-churn workloads, set `heartbeat_interval` as high as your recovery objectives allow, and keep it less than `orphan_threshold`. This reduces writes to the monitoring tables. If Solid Queue uses PostgreSQL and request volume is high, tune autovacuum for the queue database tables. The `patient_http_solid_queue_inflight_requests` table has heavy insert, update, and delete traffic by design.

> [!IMPORTANT]
> This gem behaves differently from synchronous HTTP requests when capacity runs out. If slow asynchronous requests reach `max_connections`, new requests raise an error in their Active Job. The job retries on this error with polynomial backoff until the processor has capacity.
>
> Slow synchronous requests fill the worker pool instead, and Solid Queue can't dequeue new jobs until a worker thread is free.
>
> The asynchronous behavior is usually better. Solid Queue keeps processing other jobs, and thousands of jobs don't get stuck in the queue.

## Metrics and monitoring

To integrate with your monitoring system, register `after_completion` and `after_error` callbacks:

```ruby
PatientHttp::SolidQueue.after_completion do |response|
  StatsD.timing("patient_http.duration", response.duration * 1000)
  StatsD.increment("patient_http.status.#{response.status}")
end

PatientHttp::SolidQueue.after_error do |error|
  error_type = error.is_a?(PatientHttp::Error) ? error.error_type : "exception"
  StatsD.increment("patient_http.error.#{error_type}")
  Rails.logger.error("Async HTTP error: #{error.class.name} - #{error.message}")
end
```

You can register multiple callbacks. They run in the order that you register them.

## Shutdown behavior

The processor hooks into Solid Queue's worker lifecycle:

1. When Solid Queue starts a worker, the processor starts.
2. When the worker stops, the processor waits up to `shutdown_timeout` seconds for in-flight requests to finish.

### Incomplete requests

If requests are still in flight when the shutdown timeout expires, the processor interrupts them and re-enqueues their original Active Jobs. Workers run the re-enqueued jobs when they're available, so deployments and restarts don't lose work.

### Crash recovery

The gem recovers requests from crashed processes:

1. Every `heartbeat_interval` seconds, the processor updates the heartbeat timestamp of each in-flight request in the database.
2. One processor at a time checks for requests that haven't had a heartbeat update in `orphan_threshold` seconds.
3. The gem re-enqueues the original Active Job for each orphaned request.

If a worker process crashes, another process retries its in-flight requests.

## Testing

The gem supports Active Job test adapters. In test mode (`PatientHttp.testing?`), requests run synchronously and block until they finish. This lets you test the full request and response cycle without a running processor.

## Installation

Add the gem to your application's Gemfile:

```ruby
gem "patient_http-solid_queue"
```

Then run:

```bash
bundle install
```

The gem's tables track in-flight requests for crash recovery and monitoring. They must be in the same database as Solid Queue.

The install task copies migrations to the migration path of the `queue` database, which is usually `db/queue_migrate`. Make sure your `queue` database configuration defines its own migration path.

For SQLite:

```yaml
development:
  primary:
    adapter: sqlite3
    database: storage/development.sqlite3
  queue:
    adapter: sqlite3
    database: storage/development_queue.sqlite3
    migrations_paths:
      - db/queue_migrate
```

For PostgreSQL:

```yaml
development:
  primary:
    adapter: postgresql
    database: my_app_development
  queue:
    adapter: postgresql
    database: my_app_queue_development
    migrations_paths:
      - db/queue_migrate
```

Install the migrations and run them:

```bash
bin/rails patient_http_solid_queue:install:migrations
bin/rails db:migrate:queue
```

If your Solid Queue database isn't named `queue`, pass its name in the `DATABASE` variable:

```bash
bin/rails patient_http_solid_queue:install:migrations DATABASE=solid_queue
bin/rails db:migrate:solid_queue
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http-solid_queue).

Follow the [standardrb](https://github.com/testdouble/standard) style, and run `standardrb --fix` before you submit.

Run the test suite:

```bash
bundle exec rake
```

The `test_app` directory has an app for manual testing. Install its dependencies:

```bash
bundle exec rake test_app:bundle
```

Start the server, which listens on `http://localhost:9292`:

```bash
bundle exec rake test_app
```

## Further reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
