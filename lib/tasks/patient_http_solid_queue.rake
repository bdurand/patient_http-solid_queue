# frozen_string_literal: true

if Rake::Task.task_defined?("patient_http_solid_queue:install:migrations")
  Rake::Task["patient_http_solid_queue:install:migrations"].clear
end

namespace :patient_http_solid_queue do
  namespace :install do
    desc "Copy migrations from patient_http_solid_queue to the queue database migration path"
    task migrations: :"db:load_config" do
      ENV["FROM"] = "patient_http_solid_queue"
      ENV["DATABASE"] = "queue" if ENV["DATABASE"].nil? || ENV["DATABASE"].empty?

      if Rake::Task.task_defined?("railties:install:migrations")
        Rake::Task["railties:install:migrations"].invoke
      else
        Rake::Task["app:railties:install:migrations"].invoke
      end
    end
  end
end
