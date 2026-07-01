# Register collavre_linear integration setting keys with the central registry.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:linear_api_endpoint,    category: "linear", sensitive: false, requires_restart: false)
  registry.register(:linear_webhook_secret,  category: "linear", sensitive: true,  requires_restart: false)
end
