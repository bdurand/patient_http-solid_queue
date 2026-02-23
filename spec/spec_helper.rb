# frozen_string_literal: true

require "bundler/setup"
require "active_record/railtie"
require "active_job/railtie"
require "logger"

require_relative "../lib/patient_http-solid_queue"

Warning[:experimental] = false if Warning.respond_to?(:[]=)

quiet_logger = Logger.new(File::NULL)
Rails.logger = quiet_logger if defined?(Rails)
ActiveJob::Base.logger = quiet_logger

# Set up in-memory SQLite3 database for Active Record
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Stub SolidQueue lifecycle hook methods that get called when the gem loads
# (SolidQueue.on_worker_start / on_worker_stop are defined by solid_queue itself)

require_relative "../db/migrate/20260216000000_create_solid_queue_async_http_tables"

# Silence Solid Queue logs during test runs.
SolidQueue.logger = quiet_logger if SolidQueue.respond_to?(:logger=)

# SolidQueue::Record lives in the gem's app/models directory and is normally
# loaded by Rails' autoloader. We load it directly for the test environment.
load(File.join(
  Gem.find_files("solid_queue.rb").first.sub("/lib/solid_queue.rb", ""),
  "app/models/solid_queue/record.rb"
))

# Create tables via migrations to avoid schema drift.
ActiveRecord::Migration.verbose = false
CreatePatientHttpSolidQueueTables.migrate(:up)

# Configure Active Job test adapter
ActiveJob::Base.queue_adapter = :test

# Enable testing mode
PatientHttp.testing = true

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed

  config.before(:each) do
    PatientHttp::SolidQueue.reset!
    PatientHttp::SolidQueue::TaskMonitor.clear_all!
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear if ActiveJob::Base.queue_adapter.respond_to?(:enqueued_jobs)
  end
end
