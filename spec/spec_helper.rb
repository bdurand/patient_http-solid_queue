# frozen_string_literal: true

require "bundler/setup"

# SimpleCov must be started before requiring the lib
begin
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
  end
rescue LoadError
  # SimpleCov is not available
end

# Rails must be defined before Bundler.require loads solid_queue, whose
# engine subclasses Rails::Engine.
require "active_record/railtie"
require "active_job/railtie"
require "logger"

Bundler.require(:default, :test)

require_relative "../lib/patient_http-solid_queue"

Warning[:experimental] = false if Warning.respond_to?(:[]=)

quiet_logger = Logger.new(File::NULL)
Rails.logger = quiet_logger if defined?(Rails)
ActiveJob::Base.logger = quiet_logger

# Set up a file-backed SQLite3 database for Active Record. An in-memory
# database is private to each pooled connection, so the gem's own threads
# (completion workers, the task monitor thread) would see empty tables. A
# shared temporary file gives every connection the same database.
require "tmpdir"
test_db_path = File.join(Dir.mktmpdir("patient_http_solid_queue"), "test.sqlite3")
at_exit { FileUtils.rm_rf(File.dirname(test_db_path)) }
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: test_db_path,
  pool: 25,
  timeout: 5000
)

# Stub SolidQueue lifecycle hook methods that get called when the gem loads
# (SolidQueue.on_worker_start / on_worker_stop are defined by solid_queue itself)

require_relative "../db/migrate/20260216000000_create_solid_queue_async_http_tables"

# Silence Solid Queue logs during test runs.
SolidQueue.logger = quiet_logger if SolidQueue.respond_to?(:logger=)

# SolidQueue::Record lives in the gem's app/models directory and is normally
# loaded by Rails' autoloader. We load it directly for the test environment,
# together with any concerns it includes. A concern file reopens the class
# without a superclass, so the class must exist with its real superclass
# before the concern loads.
unless SolidQueue.const_defined?(:Record, false)
  solid_queue_root = Gem.find_files("solid_queue.rb").first.sub("/lib/solid_queue.rb", "")
  record_concerns = Dir[File.join(solid_queue_root, "app/models/solid_queue/record/*.rb")].sort
  if record_concerns.any?
    SolidQueue.const_set(:Record, Class.new(ActiveRecord::Base))
    record_concerns.each { |concern| load(concern) }
  end
  load(File.join(solid_queue_root, "app/models/solid_queue/record.rb"))
end

# Create tables via migrations to avoid schema drift.
ActiveRecord::Migration.verbose = false
CreatePatientHttpSolidQueueTables.migrate(:up)

# Configure Active Job test adapter
ActiveJob::Base.queue_adapter = :test

# Enable testing mode
PatientHttp.testing = true

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |file| require file }

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
