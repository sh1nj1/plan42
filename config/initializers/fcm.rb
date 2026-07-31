# Register Firebase/FCM keys with the IntegrationSettings registry so the admin
# UI can surface them and `Collavre::IntegrationSettings::Resolver` can serve
# values via the DB > ENV > credentials precedence. Registered eagerly because
# the FCM client is wired into `Rails.application.config.x.*` at boot.
#
# Firebase JS-config keys are also registered here defensively: this initializer
# (`fcm.rb`) loads before `firebase_config.rb` alphabetically, so without these
# guards `IntegrationSettings.fetch(:firebase_*)` would raise `UnknownKeyError`
# and the helper would swallow it to nil — losing the ENV fallback. `register`
# is idempotent (last write wins), so `firebase_config.rb` re-registering is safe.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:firebase_project_id,             category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_service_account_json,   category: "firebase", sensitive: true,  requires_restart: true,
                                                      input_type: :textarea)
  registry.register(:fcm_wif_audience,                category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:fcm_wif_credential_source,       category: "firebase", sensitive: true,  requires_restart: true,
                                                      input_type: :textarea)
  # No custom env_var: the default (FCM_WIF_SERVICE_ACCOUNT_EMAIL == key.upcase)
  # MUST match key.upcase. `IntegrationSettings.fetch(boot_safe: true)` — used
  # by the deferred FCM configuration — falls back to ENV[key.upcase] when the
  # DB is unreachable,
  # while the runtime Resolver reads ENV[env_var]. A custom env_var splits the
  # two, so a value present at runtime is absent at boot (see creative #14282:
  # the WIF impersonation URL was never built → every push failed Unauthorized).
  registry.register(:fcm_wif_service_account_email,   category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:fcm_sender_id,                   category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:fcm_vapid_key,                   category: "firebase", sensitive: true,  requires_restart: true)
  registry.register(:fcm_server_key,                  category: "firebase", sensitive: true,  requires_restart: true)
  # Hidden from admin UI: ADC file path is a developer-local convenience read
  # from ENV/credentials only. Production should use firebase_service_account_json
  # (DB textarea) or WIF instead.
  registry.register(:google_application_credentials,  category: "firebase", sensitive: true,  requires_restart: true,
                                                      admin_visible: false)
end

# FCM configuration reads encrypted integration settings from the database.
# Defer it until Rails has finished eager loading so IntegrationSetting is
# available; otherwise production boot silently falls back to ENV and can pick
# the legacy WIF path even when an admin saved a service account JSON key.
Rails.application.config.after_initialize do
  require Rails.root.join("config/fcm_configuration").to_s
end
