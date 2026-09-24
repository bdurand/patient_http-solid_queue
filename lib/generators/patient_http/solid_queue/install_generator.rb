# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/migration"
require "rails/generators/active_record"

module PatientHttp
  module SolidQueue
    # Installs the crash recovery migration and a commented initializer.
    #
    # The migration must run on the database that Solid Queue uses. The
    # generator finds that database in `config/database.yml` and copies the
    # migration to its migrations path, so a multi-database application needs
    # no extra arguments. To name the database explicitly, pass `--database`.
    #
    # @example
    #   bin/rails generate patient_http:solid_queue:install
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
        # Returns the timestamp prefix for the new migration.
        #
        # @param dirname [String] The directory that the migration is copied to.
        # @return [String] The timestamp prefix.
        def next_migration_number(dirname)
          ::ActiveRecord::Generators::Base.next_migration_number(dirname)
        end
      end

      # Copies the migration to the Solid Queue database's migrations path.
      #
      # @return [void]
      def copy_migration
        migration_template(
          "create_patient_http_solid_queue_tables.rb.erb",
          File.join(migration_directory, "create_patient_http_solid_queue_tables.rb"),
          migration_version: migration_version
        )
      end

      # Creates `config/initializers/patient_http.rb`, unless
      # `--skip-initializer` is set.
      #
      # @return [void]
      def create_initializer
        return if options[:skip_initializer]

        template("initializer.rb", "config/initializers/patient_http.rb")
      end

      # Prints the migrate command and a usage example.
      #
      # @return [void]
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

      # Returns the migrations path of the database that Solid Queue uses. For
      # single-database applications, falls back to `db/migrate`.
      #
      # @return [String] The migrations path.
      def migration_directory
        @migration_directory ||= begin
          path = Array(database_config&.migrations_paths).first
          path || "db/migrate"
        end
      end

      # Returns the configuration of the database that Solid Queue uses.
      #
      # The generator checks the following, in order:
      #
      # 1. The database named by `--database`.
      # 2. A database named `queue`, which is the Rails default for Solid Queue.
      # 3. Any database whose name contains `queue`.
      # 4. The primary database.
      #
      # @return [ActiveRecord::DatabaseConfigurations::DatabaseConfig, nil] The
      #   database configuration, or `nil` if `config/database.yml` can't be
      #   read.
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

      # Returns the Rake task that runs the migration on the detected database.
      #
      # @return [String] The task name.
      def migrate_task
        name = database_config&.name
        return "db:migrate" if name.nil? || name == "primary"

        "db:migrate:#{name}"
      end

      # @return [String] The Rails version stamp for the generated migration
      #   class.
      def migration_version
        "[#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
