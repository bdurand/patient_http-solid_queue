# PatientHttp::SolidQueue

[![Continuous Integration](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http-solid_queue.svg)](https://badge.fury.io/rb/patient_http-solid_queue)

*Built for APIs that like to think.*

This gem runs HTTP requests from Solid Queue on a dedicated async I/O processor in your Solid Queue worker process, using the [patient_http gem](https://github.com/bdurand/patient_http). Worker threads don't wait for HTTP responses, so they're free to run other jobs while requests are in flight.

## Motivation

Solid Queue works best when jobs finish quickly. A long HTTP request blocks a worker thread, so other jobs wait, latency rises, and throughput drops. LLM and other AI APIs make this worse, because a request can take many seconds to finish.

Without this gem, each slow request holds a worker thread for its full duration:

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

With this gem, a worker thread only hands off the request, and the async processor waits for the response:

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

The async processor runs in a dedicated thread in your Solid Queue worker process. It uses Ruby's fiber-based concurrency to run hundreds of HTTP requests at the same time without blocking. When a request finishes, the gem calls your callback service.

## Quick start

### 1. Install the gem

Add the gem to your Gemfile:

```ruby
gem "patient_http-solid_queue"
```

Then install it, run the install generator, and run the migration:

```bash
bundle install
bin/rails generate patient_http:solid_queue:install
bin/rails db:migrate
```

The generator creates the migration for the crash-recovery tables and a commented initializer to start from. For details, including multi-database setups, see [Installation](#installation).

No other setup is required. When the gem loads, it registers the request handler and connects the processor to Solid Queue's startup and shutdown. You don't need to call a setup method. Every option has a working default. To change the defaults, see [Configuration](#configuration).

### 2. Create a callback service

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

### 3. Make HTTP requests

Make HTTP requests from anywhere in your code with the `PatientHttp` module:

```ruby
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
  callback: FetchDataCallback,
  callback_args: {user_id: user_id}
)
```

The gem enqueues the request as an Active Job, which runs the request on a [PatientHttp](https://github.com/bdurand/patient_http) processor. When the request finishes, another Active Job calls your callback's `on_complete` method. If the request fails, the job calls `on_error` instead.

The `response.callback_args` and `error.callback_args` methods return the arguments that you passed with the `callback_args` option.

For other HTTP methods, use `PatientHttp.post`, `PatientHttp.put`, `PatientHttp.patch`, `PatientHttp.delete`, `PatientHttp.head`, and `PatientHttp.query`. For the full API reference, see the [patient_http documentation](https://github.com/bdurand/patient_http).

> [!IMPORTANT]
> Don't raise an error in `on_error` to retry the request. Active Job retries the callback job, not the request. To retry the request, make a new request from `on_error`. Make sure that the retries stop if the error persists, or they can loop forever.
>
> The `on_error` callback runs only when the request raises an exception, such as a timeout or a connection failure. By default, HTTP error status codes (4xx and 5xx) don't call `on_error`. The gem treats these responses as completed requests and passes them to `on_complete`. To treat HTTP errors as exceptions, see [Handle HTTP error responses](#handle-http-error-responses).

## Usage

### Make requests

Use the `PatientHttp` module methods to make requests. There's a method for each HTTP method:

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

The methods take these options:

| Option | Description |
| --- | --- |
| `callback:` | Required. The callback service class, or its name. |
| `callback_args:` | A Hash of arguments that the callback reads from the response or error. See [Callback arguments](#callback-arguments). |
| `headers:` | The request headers. |
| `body:` | The request body. GET, HEAD, and DELETE requests can't have a body. |
| `json:` | An object to send as a JSON body. Can't be combined with `body:`. |
| `params:` | Query parameters to add to the URL. |
| `timeout:` | The request timeout in seconds. |
| `raise_error_responses:` | Whether to treat non-2xx responses as errors. See [Handle HTTP error responses](#handle-http-error-responses). |
| `processor:` | The name of the processor that runs the request. See [Named processors](#named-processors). |

For all options, see the [patient_http documentation](https://github.com/bdurand/patient_http#make-requests).

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

### Handle HTTP error responses

By default, the gem treats HTTP error status codes (4xx and 5xx) as completed requests and passes them to `on_complete`. To check the status, use `response.success?`, `response.client_error?`, or `response.server_error?`:

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

To treat HTTP errors as exceptions, set the `raise_error_responses` option. With this option, a non-2xx response calls `on_error` with a `PatientHttp::HttpError` instead:

```ruby
class ApiCallback
  def on_complete(response)
    # Called only for 2xx responses.
    process_data(response.json)
  end

  def on_error(error)
    # Called for exceptions, and for HTTP errors when raise_error_responses is set.
    if error.is_a?(PatientHttp::HttpError)
      # The response is available from error.response.
      Rails.logger.error("HTTP #{error.status} from #{error.url}: #{error.response.body}")
    else
      # Request errors, such as timeouts and connection failures.
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

An `HttpError` gives you access to the request and the response:

```ruby
def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status              # HTTP status code
    puts error.url                 # Request URL
    puts error.http_method         # HTTP method
    puts error.response.body       # Response body
    puts error.response.headers    # Response headers
    puts error.response.json       # Response body parsed as JSON
  end
end
```

### Named processors

By default, all requests share one processor and one `max_connections` limit. If one process runs workloads with very different profiles, such as slow LLM API calls and fast webhook deliveries, a burst of one workload can use all the capacity that the other needs. Named processor profiles keep the workloads separate:

```ruby
PatientHttp.configure do |config|
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)
end
```

Each profile runs as an independent processor in the process, with its own capacity, timeouts, and threads. Profile options override the top-level configuration. The profiles share every option that they don't override, such as secrets, preprocessors, payload stores, encryption, and the logger. The `:default` processor always exists. To override its options, declare `config.processor(:default, ...)`.

To send a request to a processor, use any of these methods:

```ruby
# An option on the request method.
PatientHttp.get(url, callback: MyCallback, processor: :llm)

# A request object. The processor is kept through serialization, retries, and crash recovery.
request = PatientHttp::Request.new(:get, url, processor: :llm)

# A request template.
template = PatientHttp::RequestTemplate.new(base_url: url, processor: :llm)
```

A request that names a processor that isn't declared in the process making the request raises `PatientHttp::UnknownProcessorError`, so a misspelled name fails where the request is made. Declare processors in an initializer that every process loads, such as the web server and the Solid Queue workers, not only in code that runs in worker processes.

The processor name is saved in the job arguments, so Active Job retries and crash recovery send the request to the same processor. If a job names a processor that isn't configured in the process that runs it, the job raises `PatientHttp::UnknownProcessorError`, and Active Job retries it with backoff. As a result, you can roll out a new profile name gradually. Jobs enqueued by earlier versions of the gem run on the `:default` processor.

### Use request templates

To share settings across requests to the same API, use `PatientHttp::RequestTemplate`:

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

If the template doesn't set a `timeout`, the configured `request_timeout` applies.

### Use the RequestHelper module

For a class that makes many requests, include `PatientHttp::RequestHelper`. The module adds the `async_get`, `async_head`, `async_post`, `async_put`, `async_patch`, `async_delete`, `async_query`, and `async_request` instance methods. To set shared options such as `base_url`, `headers`, and `timeout`, use the `request_template` class method:

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

The `async_*` methods take the same options as `PatientHttp.get`, `PatientHttp.post`, and the other module methods. Paths are relative to the template's `base_url`.

For the full `RequestHelper` documentation, see the [patient_http documentation](https://github.com/bdurand/patient_http#use-the-requesthelper-module).

### Callback arguments

To pass data to your callbacks, use the `callback_args` option:

```ruby
class FetchDataCallback
  def on_complete(response)
    # Read callback_args with symbol or string keys.
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

# Pass data with the callback_args option.
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  callback: FetchDataCallback,
  callback_args: {
    user_id: user_id,
    request_timestamp: Time.now.iso8601
  }
)
```

The `callback_args` value follows these rules:

- It must be a Hash, or respond to `to_h`, and contain only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, and `Hash`.
- Hash keys are converted to strings, including the keys of nested hashes and of hashes in arrays.
- You can read the arguments with symbol or string keys: `callback_args[:user_id]` or `callback_args["user_id"]`.
- Reading a key that isn't set raises a `KeyError`. To get a default value instead, use `callback_args.fetch(:user_id, nil)`.

### Protect sensitive data

The gem stores requests and responses in your queue database so that it can run the callback job. If they contain sensitive data, that data is stored in plain text.

To protect the data, configure encryption. The gem then encrypts all request and response data before it stores the data in the queue, and decrypts the data when it reads it.

#### Use an encryption key

The simplest option is `encryption_key=`. It uses [ActiveSupport::MessageEncryptor](https://api.rubyonrails.org/classes/ActiveSupport/MessageEncryptor.html) with AES-256-GCM:

```ruby
PatientHttp.configure do |config|
  config.encryption_key = Rails.application.credentials.patient_http_encryption_key
end
```

To rotate keys, pass an array. The first key encrypts data, and all keys are tried for decryption:

```ruby
PatientHttp.configure do |config|
  config.encryption_key = [
    Rails.application.credentials.patient_http_encryption_key,
    Rails.application.credentials.patient_http_old_key
  ]
end
```

#### Use custom callables

To use another encryption library, provide callables that take and return raw bytes as a String:

```ruby
PatientHttp.configure do |config|
  config.encryption { |bytes| MyEncryption.encrypt(bytes) }
  config.decryption { |bytes| MyEncryption.decrypt(bytes) }
end
```

You can also pass any object that responds to `call`:

```ruby
PatientHttp.configure do |config|
  config.encryption(->(bytes) { MyEncryption.encrypt(bytes) })
  config.decryption(->(bytes) { MyEncryption.decrypt(bytes) })
end
```

To keep API tokens out of the queue entirely, use secrets instead. For secrets, request preprocessors, and payload stores for large payloads, see the [patient_http documentation](https://github.com/bdurand/patient_http#sensitive-and-large-payloads).

## Configuration

All configuration is optional. To set options, call `PatientHttp.configure` in an initializer. The method yields this gem's configuration. `PatientHttp::SolidQueue.configure` does the same thing, but `PatientHttp.configure` keeps the initializer free of references to the job system.

Every call yields the same configuration object, so options accumulate. Several initializers can each set options without overwriting one another.

```ruby
PatientHttp.configure do |config|
  # Maximum concurrent HTTP requests (default: 256).
  config.max_connections = 256

  # Default timeout for HTTP requests in seconds (default: 60).
  config.request_timeout = 60

  # Maximum number of host clients to pool (default: 100).
  config.connection_pool_size = 100

  # Timeout in seconds to open a connection, including the TCP connect and the
  # TLS handshake (default: nil, no limit). It doesn't limit the wait for a
  # response; request_timeout does that.
  config.connection_timeout = 10

  # TCP keepalive for pooled connections (default: nil, the kernel sends no
  # probes). A number sets the idle seconds before the first probe. A Hash also
  # sets the interval and the probe count, for example
  # {idle: 30, interval: 10, count: 3}. The Hash must contain :idle. The
  # :interval default is 10 seconds, and the :count default is 3 probes.
  config.tcp_keepalive = 30

  # Seconds that sent data can stay unacknowledged before the kernel closes the
  # connection (default: nil, the kernel default applies). Sets
  # TCP_USER_TIMEOUT, which is available only on Linux.
  config.tcp_user_timeout = 30

  # Number of retries for failed requests (default: 3).
  config.retries = 3

  # HTTP or HTTPS proxy URL (default: nil). Supports authentication, for
  # example "http://user:pass@proxy.example.com:8080".
  config.proxy_url = "http://proxy.example.com:8080"

  # Default User-Agent header for all requests (default: "PatientHttp").
  config.user_agent = "MyApp/1.0"

  # Timeout for graceful shutdown in seconds (default: the Solid Queue shutdown
  # timeout minus 2 seconds). Must be less than Solid Queue's shutdown timeout.
  config.shutdown_timeout = 23

  # Maximum response body size in bytes (default: 1MB). Larger responses raise
  # ResponseTooLargeError.
  config.max_response_size = 1024 * 1024

  # Maximum number of redirects to follow (default: 5; 0 turns off redirects).
  config.max_redirects = 5

  # Whether to raise HttpError for non-2xx responses by default (default: false).
  config.raise_error_responses = false

  # Heartbeat interval for crash recovery in seconds (default: 60).
  config.heartbeat_interval = 60

  # Seconds without a heartbeat after which a request is re-enqueued
  # (default: 300).
  config.orphan_threshold = 300

  # Size in bytes above which payloads are stored externally when a payload
  # store is configured (default: 64KB).
  config.payload_store_threshold = 64 * 1024

  # Queue name for RequestJob and CallbackJob (default: nil, the Active Job
  # default queue).
  config.queue_name = "patient_http"

  # Number of threads that decode responses and deliver results (default: 2).
  config.completion_threads = 2

  # Maximum connections to each host (default: nil, no limit).
  config.max_connections_per_host = 32

  # Named processor profiles for workload isolation. See Named processors.
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)

  # Handler that runs when a callback job is discarded. See Handle exhausted
  # retries.
  config.on_retries_exhausted { |error| MyAlertService.notify(error) }

  # Logger (default: SolidQueue.logger).
  config.logger = Rails.logger

  # Encryption for sensitive data. See Protect sensitive data.
  config.encryption_key = Rails.application.credentials.patient_http_encryption_key
end
```

For all options, see the [Configuration](lib/patient_http/solid_queue/configuration.rb) class. For the HTTP options that this gem inherits, see the [patient_http documentation](https://github.com/bdurand/patient_http#configuration).

### Tuning tips

- `max_connections`: Set this based on your system's resources. Each connection uses memory and a file descriptor. A tuned system with enough resources can handle thousands of concurrent connections.
- `request_timeout`: Set this based on the response times of the APIs that you call. AI APIs can take minutes to respond while they generate content.
- `connection_pool_size`: Sets the maximum number of hosts whose connections are kept open. Increase it if your application calls many different hosts.
- `connection_timeout`: Limits only the TCP connect and the TLS handshake. Set it to fail fast when a host doesn't answer. It doesn't limit the wait for a response, because `request_timeout` controls the full exchange.
- `retries`: Sets the number of times to retry a failed request before the gem calls the error callback.
- `max_response_size`: Limits the size of HTTP responses to prevent high memory use from unexpectedly large responses. Responses are serialized in Active Job arguments, and very large responses can slow the queue database down. Text response bodies are compressed to save space. Binary bodies are Base64 encoded, which increases their size by about 33%.
- `payload_store_threshold`: Lower this if large payloads slow your queue down. Higher values avoid extra reads and writes to the payload store.
- `max_connections_per_host`: Limits the sockets open to each host. Make sure that the process file descriptor limit covers `max_connections`, plus idle pooled connections, plus the application's own connections. Raise the limit if needed.
- `shutdown_timeout`: Must be less than the process supervisor's stop timeout, so that in-flight requests finish before a hard kill. The default is based on Solid Queue's shutdown timeout. If a container orchestrator or init system also stops the process, check its stop timeout as well.
- `completion_threads`: Increase this when result delivery does heavy work, such as serialization or encryption, and finished requests wait for a thread. Size the Active Record connection pool to cover these threads, the task monitor thread, and the worker threads.
- `heartbeat_interval` and `orphan_threshold`: For high-volume workloads, set `heartbeat_interval` as high as your recovery objective allows, while you keep it less than `orphan_threshold`. Fewer heartbeats mean fewer writes to the crash-recovery tables. If Solid Queue uses PostgreSQL and the request volume is high, tune autovacuum for the queue database tables. The `inflight_requests` table has many inserts, updates, and deletes by design.

> [!IMPORTANT]
> When the processor reaches `max_connections`, a new request raises an error in its Active Job. The job retries with polynomial backoff until the processor has capacity.
>
> Synchronous HTTP requests in Solid Queue jobs behave differently. Slow synchronous requests fill the worker pool, and no new jobs start until a worker thread is free.
>
> The asynchronous behavior is usually better, because Solid Queue keeps running other jobs, and thousands of jobs don't pile up in the queue.

## Metrics and monitoring

### Monitoring callbacks

To send metrics to your monitoring system, register `after_completion` and `after_error` callbacks:

```ruby
PatientHttp::SolidQueue.after_completion do |response|
  StatsD.timing("patient_http.duration", response.duration * 1000)
  StatsD.increment("patient_http.status.#{response.status}")
end

PatientHttp::SolidQueue.after_error do |error|
  StatsD.increment("patient_http.error.#{error.error_type}")
  Sentry.capture_message("Async HTTP error: #{error.message}")
end
```

You can register more than one callback. Callbacks run in the order that you register them.

### Handle exhausted retries

Callback jobs aren't retried by default. To retry a failed callback job before Active Job discards it, configure `retry_on` in an initializer:

```ruby
PatientHttp::SolidQueue::CallbackJob.retry_on StandardError, wait: :polynomially_longer, attempts: 5
```

When Active Job discards a callback job, the gem can call an `on_retries_exhausted` handler. Use the handler to send an alert or to record that a callback failed permanently. The handler receives the same error object as `on_error`:

```ruby
PatientHttp.configure do |config|
  config.on_retries_exhausted do |error|
    Sentry.capture_message("Callback permanently failed: #{error.message}")
    DeadLetterRecord.create!(
      error_message: error.message,
      callback_args: error.callback_args
    )
  end
end
```

You can also assign any object that responds to `call`:

```ruby
PatientHttp.configure do |config|
  config.on_retries_exhausted = ->(error) { MyAlertService.notify(error) }
end
```

> [!NOTE]
> The gem calls the `on_retries_exhausted` handler only for callback jobs that deliver an error to `on_error`. If the handler raises an exception, the gem logs a warning, and the discarded job cleanup continues as usual.
>
> Active Job runs `after_discard` hooks for any unhandled exception, not only when the configured retries run out. Without `retry_on`, the first callback failure calls the `on_retries_exhausted` handler and deletes any externally stored payload. You can still retry the failed job by hand from Mission Control, but the retry fails if the payload was stored externally.

## Shutdown behavior

The async HTTP processor follows Solid Queue's lifecycle events:

1. **Startup**: The processor starts when Solid Queue starts a worker.
2. **Shutdown**: The processor waits up to `shutdown_timeout` seconds for in-flight requests to finish.

### Incomplete requests

If requests are still in flight when the shutdown timeout ends, the gem interrupts them and re-enqueues their Active Jobs. The jobs run again when Solid Queue restarts or on another worker, so no work is lost during deployments or restarts.

### Crash recovery

The gem recovers requests from processes that crash:

1. **Heartbeats**: Every `heartbeat_interval` seconds, each process updates the heartbeat times of its in-flight requests in the database.
2. **Orphan detection**: One process at a time checks for requests that haven't had a heartbeat in `orphan_threshold` seconds.
3. **Re-enqueue**: The gem re-enqueues the Active Jobs of the orphaned requests.

As a result, if a Solid Queue worker process crashes, another process retries its in-flight requests.

Crash recovery gives at-least-once delivery. If a process crashes at the wrong moment, such as between a re-enqueue and the removal of the registry entry, a request can run more than once, and its callback can run more than once. Make your callbacks idempotent. If the gem can't write a request's registry entry, the processor rejects the request, the job raises `PatientHttp::SolidQueue::RegistrationError`, and Active Job retries it.

If the gem can't hand a result to a callback job, it keeps the request's registry entry, so crash recovery re-enqueues the request.

## Testing

The gem supports the Active Job test adapters. When `RAILS_ENV`, `RACK_ENV`, or `APP_ENV` is `test`, requests run immediately in the worker thread and block until they finish. As a result, tests can check the full request and response cycle without a running processor.

## Installation

Add the gem to your Gemfile:

```ruby
gem "patient_http-solid_queue"
```

Then install it:

```bash
bundle install
```

Run the install generator, and then run the migration:

```bash
bin/rails generate patient_http:solid_queue:install
bin/rails db:migrate
```

The generator creates a migration for the crash-recovery and in-flight request tables. It also creates a commented initializer, which you can edit or delete.

The tables must be in the database that Solid Queue uses. The generator finds that database from `config.solid_queue.connects_to`, or from the database names in `config/database.yml`, and writes the migration to its migrations path, so a multi-database application needs no extra arguments. The generator prints the migrate command for the database that it chose. For a typical setup like the following, the command is `bin/rails db:migrate:queue`:

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

If the generator can't find the database, name it:

```bash
bin/rails generate patient_http:solid_queue:install --database=solid_queue
```

To generate only the migration, pass `--skip-initializer`.

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http-solid_queue).

Follow the [standardrb](https://github.com/testdouble/standard) style, and run `standardrb --fix` before you submit a pull request.

Run the tests:

```bash
bundle exec rake
```

The `test_app` directory has a test app for manual testing. To run it, install its dependencies:

```bash
bundle exec rake test_app:bundle
```

Then start the server, which runs at http://localhost:9292:

```bash
bundle exec rake test_app
```

## Further reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
