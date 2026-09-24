# PatientHttp::SolidQueue

[![Continuous Integration](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http-solid_queue.svg)](https://badge.fury.io/rb/patient_http-solid_queue)

*Built for APIs that like to think.*

This gem offloads HTTP requests from Solid Queue jobs to a dedicated async I/O processor that runs in your Solid Queue worker process. It uses the [patient_http gem](https://github.com/bdurand/patient_http). While HTTP requests are in flight, worker threads are free to run other jobs instead of waiting for responses.

## Motivation

Solid Queue assumes that jobs are short-lived. A long-running HTTP request blocks a worker thread, so other jobs wait. This increases latency and reduces throughput. The problem is worse with LLM and other AI APIs, where a request can take many seconds.

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

With this gem, workers enqueue the request and move on while the async processor waits for the responses:

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

The async processor runs in a dedicated thread in your Solid Queue worker process. It uses Ruby's fiber-based concurrency to run hundreds of HTTP requests at once without blocking. When a request completes, the gem enqueues a job that passes the result to your callback service.

## Quick start

### Install the gem

```bash
bin/rails generate patient_http:solid_queue:install
bin/rails db:migrate
```

For details, including multi-database setups, see [Installation](#installation). Loading the gem registers the request handler and connects the processor to Solid Queue's startup and shutdown, so no other setup is required. Every option has a working default. To change options, see [Configuration](#configuration).

### Create a callback service

Define a callback service class with `on_complete` and `on_error` instance methods:

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

### Make HTTP requests

Call `PatientHttp` from anywhere in your code:

```ruby
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
  callback: FetchDataCallback,
  callback_args: {user_id: user_id}
)
```

For other HTTP methods, call `PatientHttp.post`, `PatientHttp.put`, `PatientHttp.patch`, or `PatientHttp.delete`. For the full API reference, see the [patient_http docs](https://github.com/bdurand/patient_http).

### How callbacks run

The gem enqueues the request as an Active Job. The job passes the request to a [PatientHttp](https://github.com/bdurand/patient_http) processor, which runs it asynchronously. When the request completes, another Active Job calls your callback's `on_complete` method. If the request raises an error, that job calls `on_error` instead.

`response.callback_args` and `error.callback_args` return the values that you passed in the `callback_args` option.

> [!IMPORTANT]
> Don't re-raise errors in `on_error` to retry the request. Re-raising retries only the callback job. To retry the original request, enqueue a new request from `on_error`. If the error condition persists, this approach can cause an infinite retry loop, so limit the number of attempts.

Callback jobs aren't retried by default. To retry failed callbacks before Active Job discards them, configure `retry_on` in an initializer:

```ruby
PatientHttp::SolidQueue::CallbackJob.retry_on StandardError, wait: :polynomially_longer, attempts: 5
```

> [!NOTE]
> Active Job runs `after_discard` hooks for any unhandled exception, not only when the configured retries are exhausted. Without `retry_on`, the first callback failure calls the `on_retries_exhausted` handler and deletes any externally stored payload. You can still retry the failed job manually from Mission Control, but the retry fails if the payload was stored externally.

The error callback runs only when an exception occurs during the HTTP request, such as a timeout or a connection failure. By default, HTTP error status codes (4xx and 5xx) don't trigger the error callback. The gem treats these responses as completed requests and passes them to `on_complete`. To treat HTTP errors as exceptions, see [Handle HTTP error responses](#handle-http-error-responses).

### Handle HTTP error responses

By default, the gem passes responses with HTTP error status codes (4xx and 5xx) to `on_complete`. Check the status with `response.success?`, `response.client_error?`, or `response.server_error?`:

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

To treat HTTP errors as exceptions, set the `raise_error_responses` option. With this option set, a non-2xx response calls `on_error` with a `PatientHttp::HttpError`:

```ruby
class ApiCallback
  def on_complete(response)
    # Called only for 2xx responses
    process_data(response.json)
  end

  def on_error(error)
    # Called for exceptions and, with raise_error_responses, for HTTP errors
    if error.is_a?(PatientHttp::HttpError)
      # The response is available as error.response
      Rails.logger.error("HTTP #{error.status} from #{error.url}: #{error.response.body}")
    else
      # Request errors, such as timeouts and connection failures
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

`HttpError` exposes the response and the request details:

```ruby
def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status              # HTTP status code
    puts error.url                 # Request URL
    puts error.http_method         # HTTP method
    puts error.response.body       # Response body
    puts error.response.headers    # Response headers
    puts error.response.json       # Parsed JSON response body
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

# POST request with JSON body
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
| `callback_args:` | A hash of values that the callback reads from the response or error. |
| `headers:` | Request headers. |
| `body:` | Request body for POST, PUT, and PATCH requests. |
| `json:` | An object to serialize as the JSON request body. You can't use it with `body:`. |
| `params:` | Query parameters to append to the URL. |
| `timeout:` | Request timeout in seconds. |
| `raise_error_responses:` | If `true`, treats non-2xx responses as errors. |
| `processor:` | The name of the processor that runs the request. See [Named processors](#named-processors). |

For more control, build a `PatientHttp::Request` object and pass it to `PatientHttp.execute`:

```ruby
request = PatientHttp::Request.new(:get, "https://api.example.com/users/123",
  headers: {"Authorization" => "Bearer token"},
  params: {include: "profile"},
  timeout: 30
)
PatientHttp.execute(request: request, callback: MyCallback, callback_args: {user_id: 123})
```

For the full `Request` and `Response` API reference, see the [patient_http docs](https://github.com/bdurand/patient_http).

### Named processors

By default, all requests share one processor and one `max_connections` limit. A process can serve workloads with different profiles, such as slow LLM API calls and fast webhook deliveries. A burst of one workload can then use all the capacity that the other workload needs. Named processor profiles isolate them:

```ruby
PatientHttp.configure do |config|
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)
end
```

Each profile runs as an independent processor in the process, with its own capacity, timeouts, and threads. Profile options override the top-level configuration. Profiles share every option that they don't override, including secrets, preprocessors, payload stores, encryption, and the logger. The `:default` processor always exists. To override its options, declare `config.processor(:default, ...)`.

Route a request to a processor in any of these ways:

```ruby
# Pass the processor option
PatientHttp.get(url, callback: MyCallback, processor: :llm)

# Set it on a request object (kept through serialization, retries, and crash recovery)
request = PatientHttp::Request.new(:get, url, processor: :llm)

# Set it on a request template
template = PatientHttp::RequestTemplate.new(base_url: url, processor: :llm)
```

The gem serializes the processor name into the job arguments, so Active Job retries and crash recovery keep the routing. If a job names a processor that isn't configured in the process that runs it, the job raises `PatientHttp::UnknownProcessorError`, and Active Job retries it with backoff. This lets you roll out new profile names gradually. Jobs enqueued by older gem versions run on the `:default` processor.

### Use request templates

To share configuration across repeated requests to the same API, use `PatientHttp::RequestTemplate`:

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

Classes that make many async HTTP requests can include `PatientHttp::RequestHelper`. The module adds the `async_get`, `async_post`, `async_put`, `async_patch`, and `async_delete` instance methods. To set shared options such as `base_url`, `headers`, and `timeout`, define a request template with the `request_template` class method.

The gem registers the request handler when it loads, so the module needs no setup.

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

To pass data to your callbacks, use the `callback_args` option:

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

The `callback_args` option works as follows:

- The value must be a hash, or respond to `to_h`, and contain only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, and `Hash`.
- The gem converts hash keys to strings for serialization. This includes keys in nested hashes and in hashes inside arrays.
- You can read values with symbol or string keys, for example `callback_args[:user_id]` or `callback_args["user_id"]`.

### Encrypt sensitive data

To run completion callbacks, the gem stores requests and responses in your queue backend, and optionally in external storage. The data is stored in plain text, which is a security risk if it contains sensitive values.

The parent `patient_http` gem provides encryption. Set `encryption_key` to encrypt and decrypt request and response data with `ActiveSupport::MessageEncryptor`:

```ruby
PatientHttp.configure do |config|
  config.encryption_key = Rails.application.credentials.patient_http_secret
end
```

For all encryption options, including key rotation and custom encryption callables, see the [patient_http gem](https://github.com/bdurand/patient_http).

## Configuration

All configuration is optional. Set options in an initializer with `PatientHttp.configure`, which yields this gem's configuration when the gem is loaded. `PatientHttp::SolidQueue.configure` is equivalent. `PatientHttp.configure` keeps the initializer free of references to the job system.

Each call yields the same configuration object, so options accumulate. Several initializers can each set options without overwriting one another.

```ruby
PatientHttp.configure do |config|
  # Maximum number of concurrent HTTP requests (default: 256)
  config.max_connections = 256

  # Default HTTP request timeout in seconds (default: 60)
  config.request_timeout = 60

  # Maximum number of host clients to pool (default: 100)
  config.connection_pool_size = 100

  # Seconds allowed to open a connection, including the TCP connect and the
  # TLS handshake (default: nil, no limit). This doesn't limit the wait for a
  # response. The request_timeout setting sets that limit.
  config.connection_timeout = 10

  # TCP keepalive for pooled connections (default: nil, the kernel sends no
  # probes). A number sets the idle seconds before the first probe. A hash also
  # sets the probe interval and the probe count, for example
  # {idle: 30, interval: 10, count: 3}. The hash must contain :idle. The
  # :interval default is 10 seconds, and the :count default is 3 probes.
  config.tcp_keepalive = 30

  # Seconds that sent data can stay unacknowledged before the kernel closes the
  # connection (default: nil, the kernel default applies). This sets
  # TCP_USER_TIMEOUT, which is available only on Linux. Other platforms use
  # their own retransmission limits.
  config.tcp_user_timeout = 30

  # Number of retries for failed requests (default: 3)
  config.retries = 3

  # Handler called when a callback job exhausts its Active Job retries
  config.on_retries_exhausted { |error| MyAlertService.notify(error) }

  # HTTP or HTTPS proxy URL (default: nil). To authenticate, include the
  # credentials in the URL: "http://user:pass@proxy.example.com:8080"
  config.proxy_url = "http://proxy.example.com:8080"

  # Default User-Agent header for all requests (default: "SolidQueue-AsyncHttp")
  config.user_agent = "MyApp/1.0"

  # Graceful shutdown timeout in seconds
  # (default: SolidQueue.shutdown_timeout - 2). Keep this below your worker
  # shutdown timeout.
  config.shutdown_timeout = 23

  # Maximum response body size in bytes (default: 1 MB). Larger responses
  # raise PatientHttp::ResponseTooLargeError.
  config.max_response_size = 1024 * 1024

  # Maximum number of redirects to follow (default: 5). Set to 0 to disable
  # redirects.
  config.max_redirects = 5

  # Whether to raise HttpError for non-2xx responses by default (default: false)
  config.raise_error_responses = false

  # Heartbeat interval for crash recovery in seconds (default: 60)
  config.heartbeat_interval = 60

  # Orphan detection threshold in seconds (default: 300). Requests without a
  # heartbeat for longer than this are re-enqueued.
  config.orphan_threshold = 300

  # Size threshold in bytes for external payload storage (default: 64 KB).
  # When a payload store is configured, larger payloads are stored externally.
  config.payload_store_threshold = 64 * 1024

  # Queue name for RequestJob and CallbackJob (default: nil, the Active Job
  # default queue)
  config.queue_name = "async_http"

  # Number of threads that decode responses and deliver results (default: 2)
  config.completion_threads = 2

  # Maximum number of connections per host (default: nil, no limit)
  config.max_connections_per_host = 32

  # Named processor profiles for workload isolation. See "Named processors."
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)

  # Custom logger (default: SolidQueue.logger)
  config.logger = Rails.logger

  # Encryption key for sensitive data. See "Encrypt sensitive data." Accepts a
  # string, or an array of strings for key rotation. The parent patient_http
  # gem provides encryption.
  config.encryption_key = Rails.application.credentials.patient_http_secret
end
```

For all available options, see the [Configuration](lib/patient_http/solid_queue/configuration.rb) class. For the HTTP options that this gem inherits, see the [patient_http docs](https://github.com/bdurand/patient_http#configuration).

### Tuning tips

- `max_connections`: Set this based on your system's resources. Each connection uses memory and a file descriptor. A tuned system with enough resources can handle thousands of concurrent connections.
- `request_timeout`: Set this based on the expected response times of the APIs that you call. AI APIs can take minutes to respond while they generate content.
- `connection_pool_size`: Sets how many connections to different hosts stay open. Increase it if your application calls many different hosts.
- `connection_timeout`: Limits only the TCP connect and the TLS handshake. Set it to fail fast when a host doesn't answer. It doesn't limit the wait for a response. `request_timeout` limits the full exchange.
- `retries`: The number of times to retry a failed request before the gem calls the error callback.
- `max_response_size`: Limits the size of HTTP responses, so an unexpectedly large response can't use too much memory. Responses are serialized as Active Job arguments, and very large responses can cause performance issues. The gem compresses text response bodies. Binary response bodies are Base64-encoded, which increases their size by about 33%.
- `payload_store_threshold`: Lower this if your queue backend struggles with large payloads. Higher values avoid extra reads and writes to external storage.
- `max_connections_per_host`: Limits the sockets per host. Make sure the process file descriptor limit covers `max_connections`, plus idle pooled host connections, plus your application's own connections. Raise the limit if needed.
- `completion_threads`: The number of threads that decode responses and deliver results (default: 2). Increase it when result callbacks do heavy work and completions back up. Size the Active Record connection pool to cover these threads, the task monitor thread, and the worker threads.
- `shutdown_timeout`: Must be less than the process supervisor's termination window, so the drain finishes before a hard kill. The default is derived from Solid Queue's shutdown timeout. If another supervisor has its own stop timeout, check that value too.
- `heartbeat_interval` and `orphan_threshold`: For high-churn workloads, set `heartbeat_interval` as high as your recovery objective allows, while keeping it less than `orphan_threshold`. This reduces writes to the monitoring tables. If Solid Queue uses PostgreSQL and request volume is high, tune autovacuum for the queue database tables. The `inflight_requests` table has many inserts, updates, and deletes by design.

> [!IMPORTANT]
>
> Capacity limits work differently than with synchronous HTTP requests in a Solid Queue job. When slow asynchronous requests reach the `max_connections` limit, new requests raise an error in the Active Job. The job declares `retry_on` for this error with polynomial backoff, so Active Job retries it until the processor has capacity.
>
> Slow synchronous HTTP requests, by contrast, fill the worker pool and block new jobs until a worker thread is free.
>
> The asynchronous behavior is usually better. Solid Queue keeps processing other jobs, and thousands of jobs don't get stuck in the queue.

## Metrics and monitoring

### Monitoring callbacks

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

The async HTTP processor hooks into Solid Queue's lifecycle events:

- On startup, the processor starts when Solid Queue starts a worker.
- On shutdown, the processor waits up to `shutdown_timeout` seconds for in-flight requests to complete.

### Incomplete requests

If requests are still in flight when the shutdown timeout expires, the gem does the following:

- Interrupts the in-flight requests.
- Re-enqueues the original Active Job for each interrupted request.

Workers process the re-enqueued jobs when they're available, so no work is lost during deployments or restarts.

### Crash recovery

The gem recovers the in-flight requests of a crashed process:

1. Every `heartbeat_interval` seconds, the processor updates the heartbeat timestamps of its in-flight requests in the database.
2. One processor at a time periodically checks for requests that haven't had a heartbeat update in `orphan_threshold` seconds.
3. The gem re-enqueues the original Active Job for each orphaned request.

If a worker process crashes, another process retries its in-flight requests.

## Testing

The gem supports Active Job test adapters. In test mode (`PatientHttp.testing?`), the gem runs async HTTP requests immediately in the worker thread and blocks until they complete. Your tests can verify the full request and response cycle without a running async processor.

## Installation

Add the gem to your application's Gemfile:

```ruby
gem "patient_http-solid_queue"
```

Install it:

```bash
bundle install
```

Run the install generator, and then run the migration:

```bash
bin/rails generate patient_http:solid_queue:install
bin/rails db:migrate
```

The generator creates a migration for the crash recovery and in-flight request tables. It also creates a commented initializer, which you can edit or delete.

The tables must be in the database that Solid Queue uses. The generator reads `config/database.yml`, finds that database, and writes the migration to its migrations path, so a multi-database application needs no extra arguments. The generator prints the migrate command for the database that it chose. For a typical setup like the following, the command is `bin/rails db:migrate:queue`:

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

If the database isn't named `queue` and the generator can't detect it, name the database explicitly:

```bash
bin/rails generate patient_http:solid_queue:install --database=solid_queue
```

To generate only the migration, pass `--skip-initializer`.

No other setup is required. Loading the gem registers the request handler and connects the processor to Solid Queue's worker startup and shutdown.

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http-solid_queue).

Follow the [standardrb](https://github.com/testdouble/standard) style, and run `standardrb --fix` before you submit.

Run the test suite:

```bash
bundle exec rake
```

The `test_app` directory contains an app for manual testing and experimentation. Install its dependencies:

```bash
bundle exec rake test_app:bundle
```

Start the server, which runs on http://localhost:9292:

```bash
bundle exec rake test_app
```

## Further reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the [MIT License](https://opensource.org/licenses/MIT).
