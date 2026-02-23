# PatientHttp::SolidQueue

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http-solid_queue/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http-solid_queue.svg)](https://badge.fury.io/rb/patient_http-solid_queue)

*Built for APIs that like to think.*

This gem provides a mechanism to offload HTTP requests to a dedicated async I/O processor running in your Solid Queue worker process, freeing worker threads immediately while HTTP requests are in flight.

## Motivation

Solid Queue workers are most efficient when jobs complete quickly. Long-running HTTP requests block worker capacity from processing other jobs, leading to increased latency and reduced throughput. This is particularly problematic when calling LLM or AI APIs, where requests can take many seconds to complete.

**The Problem:**

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

**The Solution:**

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

The async processor runs in a dedicated thread within your worker process, using Ruby's Fiber-based concurrency to handle hundreds of concurrent HTTP requests without blocking. When an HTTP request completes, a callback job is enqueued for processing.

## Quick Start

### 1. Create a Callback Service

Define a callback service class with `on_complete` and `on_error` methods:

```ruby
class FetchDataCallback
	def on_complete(response)
		user_id = response.callback_args[:user_id]
		data = response.json
		User.find(user_id).update!(external_data: data)
	end

	def on_error(error)
		user_id = error.callback_args[:user_id]
		Rails.logger.error("Failed to fetch data for user #{user_id}: #{error.message}")
	end
end
```

### 2. Make HTTP Requests

Make HTTP requests from anywhere in your code using `PatientHttp::SolidQueue`:

```ruby
PatientHttp::SolidQueue.get(
	"https://api.example.com/users/#{user_id}",
	callback: FetchDataCallback,
	callback_args: {user_id: user_id}
)
```

### 3. That's It!

The processor starts automatically with Solid Queue worker lifecycle hooks. When the HTTP request completes, your callback's `on_complete` method is executed as a new Active Job via `PatientHttp::SolidQueue::CallbackJob` with an `PatientHttp::Response` object.

If an error occurs during the request, the `on_error` method is called with an `PatientHttp::Error` object.

The `response.callback_args` and `error.callback_args` provide access to the arguments you passed via the `callback_args:` option. You can access them using symbol or string keys:

```ruby
response.callback_args[:user_id]    # Symbol access
response.callback_args["user_id"]   # String access
```

> [!NOTE]
> HTTP requests are made asynchronously. Calling `PatientHttp::SolidQueue.get` enqueues a `PatientHttp::SolidQueue::RequestJob` to make the request, so you can call it from anywhere in your Rails app.

> [!IMPORTANT]
> Do not re-raise errors in the `on_error` callback as a means to retry. That will just retry the callback job. If you want to retry the original request, enqueue a new request from within `on_error`. Be careful with this approach, though, as it can lead to infinite retry loops if the error condition is not resolved.
>
> Also note that the error callback is only called when an exception occurs during the HTTP request (timeout, connection failure, etc). HTTP error status codes (4xx, 5xx) do not trigger the error callback by default. Instead, they are treated as completed requests and passed to the `on_complete` callback. See the "Handling HTTP Error Responses" section below for how to treat HTTP errors as exceptions.

### Handling HTTP Error Responses

By default, HTTP error status codes (4xx, 5xx) are treated as successful responses and passed to the `on_complete` callback. You can check the status using `response.success?`, `response.client_error?`, or `response.server_error?`:

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

PatientHttp::SolidQueue.get(
	"https://api.example.com/data/#{id}",
	callback: ApiCallback
)
```

If you prefer to treat HTTP errors as exceptions, you can use the `raise_error_responses` option. When enabled, non-2xx responses call the `on_error` callback with an `PatientHttp::HttpError` instead:

```ruby
class ApiCallback
	def on_complete(response)
		# Only called for 2xx responses
		process_data(response.json)
	end

	def on_error(error)
		# Called for exceptions AND HTTP errors when using raise_error_responses
		if error.is_a?(PatientHttp::HttpError)
			# Access the response via error.response
			Rails.logger.error("HTTP #{error.status} from #{error.url}: #{error.response.body}")
		else
			# Regular request errors (timeout, connection, etc)
			Rails.logger.error("Request failed: #{error.message}")
		end
	end
end

PatientHttp::SolidQueue.get(
	"https://api.example.com/data/#{id}",
	callback: ApiCallback,
	raise_error_responses: true
)
```

The `HttpError` provides convenient access to the response:

```ruby
def on_error(error)
	if error.is_a?(PatientHttp::HttpError)
		puts error.status              # HTTP status code
		puts error.url                 # Request URL
		puts error.http_method         # HTTP method
		puts error.response.body       # Response body
		puts error.response.headers    # Response headers
		puts error.response.json       # Parse JSON response (if applicable)
	end
end
```

## Usage Patterns

### Making Requests with PatientHttp::SolidQueue

The main entry point is the `PatientHttp::SolidQueue` module, which provides convenience methods for all HTTP verbs:

```ruby
# GET request
PatientHttp::SolidQueue.get(
	"https://api.example.com/users/123",
	callback: MyCallback,
	callback_args: {user_id: 123}
)

# POST request with JSON body
PatientHttp::SolidQueue.post(
	"https://api.example.com/users",
	callback: MyCallback,
	json: {name: "John", email: "john@example.com"}
)

# PUT request
PatientHttp::SolidQueue.put(
	"https://api.example.com/users/123",
	callback: MyCallback,
	json: {name: "Updated Name"}
)

# PATCH request
PatientHttp::SolidQueue.patch(
	"https://api.example.com/users/123",
	callback: MyCallback,
	json: {status: "active"}
)

# DELETE request
PatientHttp::SolidQueue.delete(
	"https://api.example.com/users/123",
	callback: MyCallback
)
```

Available options:

- `callback:` - (required) Callback service class or class name
- `callback_args:` - Hash of arguments passed to callback via response/error
- `headers:` - Request headers
- `body:` - Request body (for POST/PUT/PATCH)
- `json:` - Object to serialize as JSON body (cannot use with body)
- `timeout:` - Request timeout in seconds
- `raise_error_responses:` - Treat non-2xx responses as errors

### Using Request Templates

For repeated requests to the same API, use `PatientHttp::RequestTemplate` to share configuration:

```ruby
class ApiService
	def initialize
		@template = PatientHttp::RequestTemplate.new(
			base_url: "https://api.example.com",
			headers: {"Authorization" => "Bearer #{ENV["API_KEY"]}"},
			timeout: 60
		)
	end

	def fetch_user(user_id)
		request = @template.get("/users/#{user_id}")
		PatientHttp::SolidQueue.execute(
			request,
			callback: FetchUserCallback,
			callback_args: {user_id: user_id}
		)
	end

	def update_user(user_id, attributes)
		request = @template.patch("/users/#{user_id}", json: attributes)
		PatientHttp::SolidQueue.execute(
			request,
			callback: UpdateUserCallback,
			callback_args: {user_id: user_id}
		)
	end
end
```

### Callback Arguments

Pass custom data to your callbacks using the `callback_args` option:

```ruby
class FetchDataCallback
	def on_complete(response)
		# Access callback_args using symbol or string keys
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

# Pass data via callback_args option
PatientHttp::SolidQueue.get(
	"https://api.example.com/users/#{user_id}",
	callback: FetchDataCallback,
	callback_args: {
		user_id: user_id,
		request_timestamp: Time.now.iso8601
	}
)
```

**Important details about callback_args:**

- Must be a Hash (or respond to `to_h`) containing only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, or `Hash`
- Hash keys will be converted to strings for serialization
- Nested hashes and hashes in arrays also have their keys converted to strings
- You can access callback_args using either symbol or string keys: `callback_args[:user_id]` or `callback_args["user_id"]`

### Sensitive Data Handling

Requests and responses from asynchronous HTTP requests may be stored in your queue backend (and optionally external storage) in order to execute completion callbacks. This can raise security concerns if they contain sensitive data.

You can configure `encryption` and `decryption` callables to encrypt request and response payloads when serialized:

```ruby
PatientHttp::SolidQueue.configure do |config|
	config.encryption { |data| MyEncryption.encrypt(data) }
	config.decryption { |encrypted_value| MyEncryption.decrypt(encrypted_value) }
end
```

The encryptor receives a hash and should return a JSON-safe value. The decryptor receives that value and should return the original hash.

## Configuration

The gem can be configured globally in an initializer:

```ruby
PatientHttp::SolidQueue.configure do |config|
	# Maximum concurrent HTTP requests (default: 256)
	config.max_connections = 256

	# Default timeout for HTTP requests in seconds (default: 60)
	config.request_timeout = 60

	# Maximum number of host clients to pool (default: 100)
	config.connection_pool_size = 100

	# Connection timeout in seconds (default: nil, uses request_timeout)
	config.connection_timeout = 10

	# Number of retries for failed requests (default: 3)
	config.retries = 3

	# HTTP/HTTPS proxy URL (default: nil)
	# Supports authentication: "http://user:pass@proxy.example.com:8080"
	config.proxy_url = "http://proxy.example.com:8080"

	# Default User-Agent header for all requests (default: "PatientHttp")
	config.user_agent = "MyApp/1.0"

	# Timeout for graceful shutdown in seconds (default: 23)
	# This should be less than your worker shutdown timeout
	config.shutdown_timeout = 23

	# Maximum response body size in bytes (default: 1MB)
	# Responses larger than this will trigger ResponseTooLargeError
	config.max_response_size = 1024 * 1024

	# Heartbeat interval for crash recovery in seconds (default: 60)
	config.heartbeat_interval = 60

	# Orphan detection threshold in seconds (default: 300)
	# Requests older than this without a heartbeat will be re-enqueued
	config.orphan_threshold = 300

	# Maximum number of redirects to follow (default: 5, 0 disables)
	config.max_redirects = 5

	# Whether to raise HttpError for non-2xx responses by default (default: false)
	config.raise_error_responses = false

	# Queue name for RequestJob and CallbackJob (default: nil, Active Job default)
	config.queue_name = "async_http"

	# Store payloads externally above this threshold in bytes (default: 64KB)
	config.payload_store_threshold = 64 * 1024

	# Optional custom logger (default: SolidQueue.logger when available)
	config.logger = Rails.logger
end
```

See the [Configuration](lib/patient_http/solid_queue/configuration.rb) class for all available options.

### Tuning Tips

- `max_connections`: Adjust based on your system resources. Each connection uses memory and file descriptors.
- `request_timeout`: Set based on the expected response time of your upstream APIs.
- `connection_pool_size`: Increase if your app talks to many different hosts.
- `connection_timeout`: Set for faster failure when network connectivity is flaky.
- `retries`: Number of retries before the error callback is invoked.
- `max_response_size`: Helps prevent unexpectedly large responses from consuming too much memory.
- `payload_store_threshold`: Lower this if your queue backend struggles with large payloads; higher values avoid extra external storage reads/writes.
- `heartbeat_interval` and `orphan_threshold`: For high-churn workloads, keep `heartbeat_interval` as large as your recovery SLO allows (while still less than `orphan_threshold`) to reduce write/update pressure on monitoring tables.
- Queue DB maintenance: If Solid Queue uses PostgreSQL and request volume is high, tune autovacuum for the queue database tables because `inflight_requests` is intentionally insert/update/delete heavy.

> [!IMPORTANT]
>
> One difference between using this gem and making synchronous HTTP calls in a job is that if `max_connections` is reached due to slow asynchronous requests, new requests will fail quickly and the parent job's retry behavior will handle re-enqueueing.
>
> In contrast, slow synchronous HTTP requests consume worker capacity and block other jobs from starting.
>
> In general, the async behavior is preferable because it allows workers to continue processing other jobs and prevents large queue backlogs caused by blocked worker threads.

## Metrics and Monitoring

### Callbacks for Custom Monitoring

You can register callbacks to integrate with your monitoring system using the `after_completion` and `after_error` hooks:

```ruby
PatientHttp::SolidQueue.after_completion do |response|
	StatsD.timing("async_http.duration", response.duration * 1000)
	StatsD.increment("async_http.status.#{response.status}")
end

PatientHttp::SolidQueue.after_error do |error|
	StatsD.increment("async_http.error.#{error.error_type}")
	Sentry.capture_message("Async HTTP error: #{error.message}")
end
```

You can register multiple callbacks; they are called in the order registered.

## Shutdown Behavior

The async HTTP processor automatically hooks in with Solid Queue worker lifecycle events.

1. **Startup:** Processor starts automatically when a worker starts
2. **Shutdown:** Processor waits up to `shutdown_timeout` seconds for in-flight requests to complete

### Incomplete Request Handling

If requests are still in-flight when shutdown times out:

- In-flight requests are interrupted
- The **original Active Job** is automatically re-enqueued
- Re-enqueued jobs are processed again when workers are available

This ensures no work is lost during deployments or restarts.

### Crash Recovery

The gem includes crash recovery to handle process failures:

1. **Heartbeat Tracking:** Every `heartbeat_interval` seconds, the processor updates heartbeat timestamps for in-flight requests in the database
2. **Orphan Detection:** A process periodically checks for requests that haven't received a heartbeat update in `orphan_threshold` seconds
3. **Automatic Re-enqueue:** Orphaned requests have their original Active Job re-enqueued

This ensures that if a worker process crashes, its in-flight requests can be retried by another process.

## Testing

The gem integrates with Active Job test adapters, and the async layer automatically runs synchronously in test mode (`PatientHttp.testing?`) so request/response flows can be tested deterministically.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "patient_http-solid_queue"
```

Then execute:

```bash
bundle install
```

Install and run the gem migrations:

```bash
bin/rails patient_http_solid_queue:install:migrations
bin/rails db:migrate
```

The database tables are used for crash recovery and monitoring of in-flight requests and need to be added to the same database that SolidQueue uses.

By default, this install task copies migrations to the `queue` database migration path (typically `db/queue_migrate`).
If your Solid Queue database name is different, override it with `DATABASE=your_database_name`.

For a typical multi-database setup, ensure your `queue` database config defines its own migration path:

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

PostgreSQL example:

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

Then run:

```bash
bin/rails patient_http_solid_queue:install:migrations
bin/rails db:queue:migrate
```

If your Solid Queue database is not named `queue`, pass its name explicitly when installing migrations:

```bash
bin/rails patient_http_solid_queue:install:migrations DATABASE=solid_queue
bin/rails db:migrate:solid_queue
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http-solid_queue).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

Run the test suite with:

```bash
bundle exec rspec
```

There is also a bundled test app in the `test_app` directory that can be used for manual testing and experimentation.

To run the test app, first install dependencies:

```bash
bundle exec rake test_app:bundle
```

Then start the app:

```bash
bundle exec rake test_app
```

## Further Reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
