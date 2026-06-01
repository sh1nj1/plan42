# Register app-level integration setting keys with the central registry and
# wire the keys whose effective values must be (re)applied on every boot.
#
# Engine-internal keys (`:default_mailer_from`, `:public_assets_host`,
# `:mcp_upload_root`) are registered inside `Collavre::Engine` itself so they
# remain owned by the engine when it is mounted as a gem in a host app.
#
# `:default_url_host` carries `requires_restart: true` because its primary
# read site (`config/application.rb`) executes before initializers; the wiring
# block below applies the DB value to mailer/controller/route URL options on
# the *next* boot so admins can change the host via `/admin/integrations`
# without redeploying.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:default_url_host, category: "mail", sensitive: false, requires_restart: true)
  registry.register(:app_host,         category: "mail", sensitive: false, requires_restart: false)
  registry.register(:rails_host,       category: "mail", sensitive: false, requires_restart: false)
  registry.register(:origin_shared_secret, category: "misc", sensitive: true, requires_restart: false)
end

# Apply DB-backed `default_url_host` (if set in admin UI) over the defaults
# established in `config/application.rb`. Skipped in `test` to match the host
# guard in `application.rb` (avoids OpenRedirect mismatches in request specs).
unless Rails.env.test? || !defined?(Collavre::IntegrationSettings)
  db_host = Collavre::IntegrationSettings.fetch(:default_url_host)
  if db_host.present?
    Rails.application.config.action_mailer.default_url_options ||= {}
    Rails.application.config.action_controller.default_url_options ||= {}
    Rails.application.config.action_mailer.default_url_options[:host] = db_host
    Rails.application.config.action_controller.default_url_options[:host] = db_host
    Rails.application.config.after_initialize do
      Rails.application.routes.default_url_options[:host] = db_host
    end
  end
end
