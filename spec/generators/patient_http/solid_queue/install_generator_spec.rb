# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require_relative "../../../../lib/generators/patient_http/solid_queue/install_generator"

RSpec.describe PatientHttp::SolidQueue::InstallGenerator do
  let(:destination) { Dir.mktmpdir("patient_http_generator") }
  let(:migration_glob) { "[0-9]*_create_patient_http_solid_queue_tables.rb" }

  around do |example|
    original_configurations = ActiveRecord::Base.configurations
    original_env = Rails.env
    original_connects_to = SolidQueue.connects_to
    begin
      Rails.env = "development"
      example.run
    ensure
      ActiveRecord::Base.configurations = original_configurations
      Rails.env = original_env
      SolidQueue.connects_to = original_connects_to
      ActiveJob::Base.queue_adapter = :test
      FileUtils.rm_rf(destination)
    end
  end

  def run_generator(*args)
    described_class.new([], ["--quiet", *args], destination_root: destination).invoke_all
  end

  def database_yml(configs)
    ActiveRecord::Base.configurations = configs
  end

  def migrations_in(directory)
    Dir.glob(File.join(destination, directory, migration_glob))
  end

  def db(name, migrations_paths = nil)
    config = {"adapter" => "sqlite3", "database" => "#{name}.sqlite3"}
    config["migrations_paths"] = migrations_paths if migrations_paths
    config
  end

  it "writes the migration to db/migrate and creates the initializer for a single database" do
    database_yml("development" => {"primary" => db("primary")})

    run_generator

    expect(migrations_in("db/migrate").size).to eq(1)
    expect(File.exist?(File.join(destination, "config/initializers/patient_http.rb"))).to be(true)
  end

  it "skips the initializer with --skip-initializer" do
    database_yml("development" => {"primary" => db("primary")})

    run_generator("--skip-initializer")

    expect(File.exist?(File.join(destination, "config/initializers/patient_http.rb"))).to be(false)
  end

  it "writes the migration to the queue database's migrations path" do
    database_yml("development" => {"primary" => db("primary"), "queue" => db("queue", "db/queue_migrate")})

    run_generator("--skip-initializer")

    expect(migrations_in("db/queue_migrate").size).to eq(1)
    expect(migrations_in("db/migrate")).to be_empty
  end

  it "uses the database that Solid Queue connects to" do
    database_yml("development" => {
      "primary" => db("primary"),
      "queue" => db("queue", "db/queue_migrate"),
      "jobs" => db("jobs", "db/jobs_migrate")
    })
    SolidQueue.connects_to = {database: {writing: :jobs}}

    run_generator("--skip-initializer")

    expect(migrations_in("db/jobs_migrate").size).to eq(1)
    expect(migrations_in("db/queue_migrate")).to be_empty
  end

  it "uses the primary database when Solid Queue runs without connects_to in the current environment" do
    database_yml(
      "development" => {"primary" => db("primary")},
      "production" => {"primary" => db("primary"), "queue" => db("queue", "db/queue_migrate")}
    )
    ActiveJob::Base.queue_adapter = :solid_queue

    run_generator("--skip-initializer")

    expect(migrations_in("db/migrate").size).to eq(1)
    expect(migrations_in("db/queue_migrate")).to be_empty
  end

  it "uses another environment's queue database when the current environment doesn't run Solid Queue" do
    database_yml(
      "development" => {"primary" => db("primary")},
      "production" => {"primary" => db("primary"), "queue" => db("queue", "db/queue_migrate")}
    )

    run_generator("--skip-initializer")

    expect(migrations_in("db/queue_migrate").size).to eq(1)
  end

  it "uses the database named by --database" do
    database_yml("development" => {"primary" => db("primary"), "other" => db("other", "db/other_migrate")})

    run_generator("--skip-initializer", "--database=other")

    expect(migrations_in("db/other_migrate").size).to eq(1)
  end

  it "raises when --database names a database that isn't configured" do
    database_yml("development" => {"primary" => db("primary")})

    expect { run_generator("--skip-initializer", "--database=missing") }.to raise_error(Rails::Generators::Error, /"missing"/)
    expect(migrations_in("db/migrate")).to be_empty
  end

  it "raises when --database is given and the database configuration can't be read" do
    allow(ActiveRecord::Base).to receive(:configurations).and_raise(RuntimeError, "bad yaml")

    expect { run_generator("--skip-initializer", "--database=queue") }.to raise_error(Rails::Generators::Error, /"queue"/)
    expect(migrations_in("db/migrate")).to be_empty
  end

  it "falls back to db/migrate when the database configuration can't be read" do
    allow(ActiveRecord::Base).to receive(:configurations).and_raise(RuntimeError, "bad yaml")

    run_generator("--skip-initializer")

    expect(migrations_in("db/migrate").size).to eq(1)
  end

  it "skips the migration when another migrations path already has one under the earlier name" do
    database_yml("development" => {"primary" => db("primary"), "queue" => db("queue", "db/queue_migrate")})
    FileUtils.mkdir_p(File.join(destination, "db/migrate"))
    File.write(File.join(destination, "db/migrate/20260101000000_create_solid_queue_async_http_tables.patient_http_solid_queue.rb"), "")

    run_generator("--skip-initializer")

    expect(migrations_in("db/queue_migrate")).to be_empty
  end
end
