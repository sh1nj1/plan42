ga_id = Rails.application.credentials.dig(:google, :analytics_id) || ENV["GOOGLE_ANALYTICS_ID"]
Rails.application.config.x.google_analytics_id = ga_id if ga_id.present?
