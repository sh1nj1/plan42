# Centralized rate limit configuration
# You can override these in each environment, e.g., in config/environments/test.rb
Rails.configuration.x.sessions_create_rate_limit ||= { to: 10, within: 3.minutes }
