CollavreSlack.configure do |config|
  config.client_id = ENV.fetch("SLACK_CLIENT_ID", config.client_id)
  config.client_secret = ENV.fetch("SLACK_CLIENT_SECRET", config.client_secret)
  config.signing_secret = ENV.fetch("SLACK_SIGNING_SECRET", config.signing_secret)
  config.redirect_uri = ENV.fetch("SLACK_REDIRECT_URI", config.redirect_uri)
  config.scopes = ENV.fetch("SLACK_SCOPES", config.scopes)
end
