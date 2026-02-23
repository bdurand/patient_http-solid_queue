# frozen_string_literal: true

Rails.application.routes.draw do
  root "test#index"

  post "run_jobs", to: "test#run_jobs"
  get "status", to: "test#status"
  get "slow", to: "test#slow"

  match "time", to: "test#time", via: :all
  match "request", to: "test#request_details", via: :all

  get "error", to: "test#error"
  get "redirect", to: "test#redirect_to_time"
end
