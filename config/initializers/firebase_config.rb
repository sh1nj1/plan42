firebase_settings = {
  apiKey: Rails.application.credentials.dig(:firebase, :api_key),
  authDomain: Rails.application.credentials.dig(:firebase, :auth_domain),
  projectId: Rails.application.credentials.dig(:firebase, :project_id),
  appId: Rails.application.credentials.dig(:firebase, :app_id),
  messagingSenderId: Rails.application.credentials.dig(:fcm, :sender_id),
  vapidKey: Rails.application.credentials.dig(:fcm, :vapid_key)
}.compact

Rails.application.config.x.firebase_config = firebase_settings if firebase_settings.present?
