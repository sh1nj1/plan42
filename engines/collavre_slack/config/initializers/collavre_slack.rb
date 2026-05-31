# Register Slack OAuth keys with the IntegrationSettings registry so the admin
# UI can surface them and `Collavre::IntegrationSettings::Resolver` can serve
# values via the DB > ENV > default precedence. Wrapped in `to_prepare` so
# definitions re-register on code reload in development.
Rails.application.config.to_prepare do
  if defined?(Collavre::IntegrationSettings::Registry)
    Collavre::IntegrationSettings::Registry.instance.register(
      :slack_client_id,      category: "slack", sensitive: false, requires_restart: true
    )
    Collavre::IntegrationSettings::Registry.instance.register(
      :slack_client_secret,  category: "slack", sensitive: true,  requires_restart: true
    )
    Collavre::IntegrationSettings::Registry.instance.register(
      :slack_signing_secret, category: "slack", sensitive: true,  requires_restart: true
    )
    Collavre::IntegrationSettings::Registry.instance.register(
      :slack_redirect_uri,   category: "slack", sensitive: false, requires_restart: true
    )
  end
end

# Scopes still come from ENV (not registered as a managed integration setting
# in Phase 1). OAuth credentials are now resolved lazily by Configuration via
# the Resolver, so they are no longer assigned here.
CollavreSlack.configure do |config|
  config.scopes = ENV.fetch("SLACK_SCOPES", config.scopes)
end
