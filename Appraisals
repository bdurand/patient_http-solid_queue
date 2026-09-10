# frozen_string_literal: true

appraise "solid_queue_1.0" do
  gem "solid_queue", "~> 1.0.0"
  gem "railties", "~> 7.1.0"
  # Active Support before 8.1 passes the quirks_mode option to JSON.generate, which json 3.0 rejects.
  gem "json", "< 3.0"
end
