# Register app-level (mailer, host, misc) integration setting keys with the
# central registry. Registered eagerly because consumers read these at boot or
# lazily through `Collavre::IntegrationSettings.fetch`.
#
# Keys whose values must be present BEFORE this initializer runs (notably
# `default_url_host` consumed by `config/application.rb`) carry
# `requires_restart: true` and continue to read from ENV directly in
# application.rb — the DB value is picked up on the next boot.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  # mailer/host
  registry.register(:default_mailer_from,  category: "mail", sensitive: false, requires_restart: true)
  registry.register(:default_url_host,     category: "mail", sensitive: false, requires_restart: true)
  registry.register(:app_host,             category: "mail", sensitive: false, requires_restart: false)
  registry.register(:rails_host,           category: "mail", sensitive: false, requires_restart: false)
  registry.register(:public_assets_host,   category: "mail", sensitive: false, requires_restart: false)
  # misc
  registry.register(:origin_shared_secret, category: "misc", sensitive: true,  requires_restart: false)
  registry.register(:mcp_upload_root,      category: "misc", sensitive: false, requires_restart: false)
end
