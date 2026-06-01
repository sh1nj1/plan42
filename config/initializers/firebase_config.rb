# Register Firebase keys with the IntegrationSettings registry so the admin UI
# can surface them and `Collavre::IntegrationSettings::Resolver` can serve
# values via the DB > ENV > credentials precedence. Registered eagerly because
# the JS config is built at boot.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:firebase_api_key,         category: "firebase", sensitive: true,  requires_restart: true)
  registry.register(:firebase_auth_domain,     category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_project_id,      category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_app_id,          category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_service_account, category: "firebase", sensitive: true,  requires_restart: true)
end

resolve = ->(key, credentials_path) {
  value = Collavre::IntegrationSettings.fetch(key)
  value.presence || Rails.application.credentials.dig(*credentials_path)
}

firebase_settings = {
  apiKey: resolve.call(:firebase_api_key,     %i[firebase api_key]),
  authDomain: resolve.call(:firebase_auth_domain, %i[firebase auth_domain]),
  projectId: resolve.call(:firebase_project_id,  %i[firebase project_id]),
  appId: resolve.call(:firebase_app_id,       %i[firebase app_id]),
  messagingSenderId: resolve.call(:fcm_sender_id, %i[fcm sender_id]),
  vapidKey: resolve.call(:fcm_vapid_key,      %i[fcm vapid_key])
}.compact

Rails.application.config.x.firebase_config = firebase_settings if firebase_settings.present?
