# Register collavre_github integration setting keys with the central registry.
# Registered eagerly (not in `to_prepare`) because `github_mock` is read at
# boot by `config/initializers/omniauth.rb`. The other keys (`webhook_secret`,
# `api_endpoint`) are resolved per request and don't strictly need eager
# registration, but we keep them together for clarity.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:github_webhook_secret, category: "github", sensitive: true,  requires_restart: false)
  registry.register(:github_api_endpoint,   category: "github", sensitive: false, requires_restart: false)
  registry.register(:github_mock,           category: "github", sensitive: false, requires_restart: true)
end
