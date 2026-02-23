# frozen_string_literal: true

require_relative "../../../lib/patient_http-solid_queue"

PatientHttp::SolidQueue.configure do |config|
  config.max_connections = ENV.fetch("MAX_CONNECTIONS", "500").to_i
  config.proxy_url = ENV["HTTP_PROXY"]
  config.register_payload_store(:files, adapter: :file, directory: Rails.root.join("tmp/payloads"))
  config.payload_store_threshold = 1024
end

PatientHttp::SolidQueue.after_completion do |response|
  Rails.logger.info("Async HTTP Continuation: #{response.status} #{response.http_method.to_s.upcase} #{response.url}")
end

PatientHttp::SolidQueue.after_error do |error|
  Rails.logger.error("Async HTTP Error: #{error.error_class.name} #{error.message} on #{error.http_method.to_s.upcase} #{error.url}")
end

unless defined?(Rake.application) && Rake.application.top_level_tasks.any? { |task| task.start_with?("db:") }
  unless defined?(::SolidQueue::Record)
    solid_queue_record_path = File.join(Gem.loaded_specs.fetch("solid_queue").full_gem_path, "app/models/solid_queue/record.rb")
    require solid_queue_record_path
  end

  PatientHttp::SolidQueue.start
  at_exit { PatientHttp::SolidQueue.stop(timeout: 5) }
end
