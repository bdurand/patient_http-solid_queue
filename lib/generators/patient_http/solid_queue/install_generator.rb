# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/migration"
require "rails/generators/active_record"

module PatientHttp
  module SolidQueue
    # Installs the crash-recovery migration and a commented initializer.
    #
    #   rails generate patient_http:solid_queue:install
    #
    # The migration has to run on the database Solid Queue uses. The generator
    # finds that database in config/database.yml and copies the migration into
    # its migrations path, so the multi-database case needs no extra arguments.
    # Pass --database to name it explicitly.
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Copies the patient_http-solid_queue migration and creates a commented initializer."

      class_option :database,
        type: :string,
        default: nil,
        desc: "Name of the database Solid Queue uses (detected from config/database.yml when omitted)"

      class_option :skip_initializer,
        type: :boolean,
        default: false,
        desc: "Skip creating config/initializers/patient_http.rb"

      class << self
        # @param dirname [String] the directory the migration is copied into
        # @return [String] the timestamp prefix for the new migration
        def next_migration_number(dirname)
          ::ActiveRecord::Generators::Base.next_migration_number(dirname)
        end
      end

      def copy_migration
        existing = existing_migration
        if existing
          say("Skipping the migration: #{existing} is already installed.", :yellow)
          return
        end

        migration_template(
          "create_patient_http_solid_queue_tables.rb.erb",
          File.join(migration_directory, "create_patient_http_solid_queue_tables.rb"),
          migration_version: migration_version
        )
      end

      def create_initializer
        return if options[:skip_initializer]

        template("initializer.rb", "config/initializers/patient_http.rb")
      end

      def show_next_steps
        say("")
        say("patient_http-solid_queue is installed.", :green)
        say("")
        say("Run the migration to create the crash-recovery tables:")
        say("")
        say("  bin/rails #{migrate_task}")
        say("")
        say("Nothing else is required: the request handler is registered when the gem")
        say("loads and the processor starts and stops with your Solid Queue workers.")
        say("")
        say("Make a request from anywhere in your application:")
        say("")
        say("  PatientHttp.get(url, callback: MyCallback, callback_args: {id: 1})")
        say("")
      end

      private

      # The migrations path of the database Solid Queue uses. Falls back to the
      # application's primary migrations path for single-database applications.
      #
      # @return [String]
      def migration_directory
        @migration_directory ||= begin
          path = Array(database_config&.migrations_paths).first

          if path.nil? && !database_config.nil? && database_config.name != "primary"
            say(
              "The #{database_config.name.inspect} database does not define migrations_paths, " \
              "so the migration is being written to db/migrate, which it shares with the primary " \
              "database. Add a migrations_paths (for example db/queue_migrate) to that database in " \
              "config/database.yml and move the migration there.",
              :yellow
            )
          end

          path || "db/migrate"
        end
      end

      # Any copy of this gem's migration that is already installed, under any of
      # the application's migration paths.
      #
      # `patient_http_solid_queue:install:migrations` copies it with the engine
      # scope in the file name (`..._create_patient_http_solid_queue_tables.
      # patient_http_solid_queue.rb`), which Rails' own duplicate check in
      # `migration_template` does not match. Writing a second copy would give two
      # migrations the same migration name and make every later `db:migrate`
      # raise ActiveRecord::DuplicateMigrationNameError.
      #
      # @return [String, nil] the path of the installed migration, relative to the
      #   application root, or nil if there is none
      def existing_migration
        paths = ::Rails.application.paths["db/migrate"].to_a
        paths |= [migration_directory]

        found = paths.flat_map do |path|
          # Paths from Rails::Paths may be relative or already absolute.
          dir = File.expand_path(path, destination_root)
          Dir[File.join(dir, "[0-9]*_create_patient_http_solid_queue_tables*.rb")]
        end.first
        return nil unless found

        relative_to_original_destination_root(found)
      end

      # The database configuration Solid Queue runs against.
      #
      # Preference order: an explicit --database, a database named "queue"
      # (the Rails default for Solid Queue), any database whose name mentions
      # the queue, then the primary database.
      #
      # @return [ActiveRecord::DatabaseConfigurations::DatabaseConfig, nil]
      def database_config
        return @database_config if defined?(@database_config)

        @database_config = begin
          configs = ::ActiveRecord::Base.configurations.configs_for(env_name: ::Rails.env)

          if options[:database]
            named = configs.find { |config| config.name == options[:database] }
            unless named
              raise ::Rails::Generators::Error.new(
                "No #{options[:database].inspect} database is configured for the " \
                "#{::Rails.env} environment in config/database.yml."
              )
            end
            named
          else
            configs.find { |config| config.name == "queue" } ||
              configs.find { |config| config.name.to_s.include?("queue") } ||
              configs.find { |config| config.name == "primary" }
          end
        rescue => e
          raise e if e.is_a?(::Rails::Generators::Error)

          # Without a readable database configuration, fall back to db/migrate
          # and let the developer move the file if it landed in the wrong place.
          say("Could not read config/database.yml (#{e.class}); using db/migrate.", :yellow)
          nil
        end
      end

      # The rake task that runs the migration for the detected database.
      #
      # @return [String]
      def migrate_task
        name = database_config&.name
        return "db:migrate" if name.nil? || name == "primary"

        # Only name the database when the migration actually went into that
        # database's own migrations path. When it fell back to db/migrate,
        # `db:migrate:<name>` would run every migration in db/migrate against
        # that database, so run the task that migrates every database instead.
        return "db:migrate" if Array(database_config.migrations_paths).first.nil?

        "db:migrate:#{name}"
      end

      # @return [String] the Rails version stamp for the generated migration class
      def migration_version
        "[#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
