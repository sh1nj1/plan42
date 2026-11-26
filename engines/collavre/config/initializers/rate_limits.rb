# Shared settings for email sign-in and sign-up. Rails keeps separate counters.
config = Rails.configuration.x
overrides = config.sessions_create_rate_limit || {}
config.sessions_create_rate_limit = { to: 10, within: 3.minutes }.merge(overrides.slice(:to, :within).compact)
