# frozen_string_literal: true

class TestController < ApplicationController
  def index
    render file: Rails.root.join("public/index.html"), layout: false
  end

  def run_jobs
    async_count = params.fetch(:async_count, 0).to_i.clamp(0, 5000)
    sync_count = params.fetch(:sync_count, 0).to_i.clamp(0, 5000)
    delay = params.fetch(:delay, 0).to_f
    timeout = params.fetch(:timeout, 30).to_f
    delay_drift = params.fetch(:delay_drift, 0).to_f.clamp(0.0, 100.0)

    StatusReport.new("Asynchronous").reset!
    StatusReport.new("Synchronous").reset!

    drifted_delay = lambda do
      actual_delay = delay
      if delay.positive? && delay_drift.positive?
        drift_fraction = delay_drift / 100.0
        lower_bound = delay * (1.0 - drift_fraction)
        upper_bound = delay * (1.0 + drift_fraction)
        actual_delay = rand(lower_bound..upper_bound).round(6)
      end
      actual_delay
    end

    base_url = request.base_url

    jobs = []
    async_count.times do
      jobs << lambda {
        PatientHttp::SolidQueue.get(
          "#{base_url}/slow?delay=#{drifted_delay.call}",
          callback: StatusReport::Callback,
          timeout: timeout
        )
      }
    end

    sync_count.times do
      jobs << lambda { SynchronousWorkerJob.perform_later("GET", "#{base_url}/slow?delay=#{drifted_delay.call}", timeout) }
    end

    jobs.shuffle.each(&:call)

    head :no_content
  end

  def status
    current_stats = CurrentStats.new
    async_stats = StatusReport.new("Asynchronous").status
    sync_stats = StatusReport.new("Synchronous").status

    render json: current_stats.to_h.merge(
      asynchronous: async_stats,
      synchronous: sync_stats
    )
  end

  def slow
    delay = params[:delay]&.to_f
    sleep(delay) if delay&.positive?
    response.set_header("Date", Time.now.httpdate)
    render plain: "start...end"
  end

  def time
    timestamp = Time.now.utc.iso8601

    if request.content_type&.start_with?("application/json")
      render json: {time: timestamp}
    else
      render plain: timestamp
    end
  end

  def request_details
    headers = request.headers.env.select { |key, _| key.start_with?("HTTP_") }.transform_keys do |key|
      key.sub(/^HTTP_/, "").split("_").map(&:downcase).join("-")
    end

    http_request = PatientHttp::Request.new(
      request.request_method.downcase.to_sym,
      request.url,
      headers: headers,
      body: request.raw_post
    )

    render json: http_request.as_json
  end

  def error
    render plain: "Internal Server Error", status: :internal_server_error
  end

  def redirect_to_time
    redirect_to "/time", allow_other_host: false
  end
end
