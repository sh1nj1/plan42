firebase_settings = {
  apiKey: ENV["FIREBASE_API_KEY"] || Rails.application.credentials.dig(:firebase, :api_key),
  authDomain: ENV["FIREBASE_AUTH_DOMAIN"] || Rails.application.credentials.dig(:firebase, :auth_domain),
  projectId: ENV["FIREBASE_PROJECT_ID"] || Rails.application.credentials.dig(:firebase, :project_id),
  appId: ENV["FIREBASE_APP_ID"] || Rails.application.credentials.dig(:firebase, :app_id),
  messagingSenderId: ENV["FCM_SENDER_ID"] || Rails.application.credentials.dig(:fcm, :sender_id),
  vapidKey: ENV["FCM_VAPID_KEY"] || Rails.application.credentials.dig(:fcm, :vapid_key)
}.compact

Rails.application.config.x.firebase_config = firebase_settings if firebase_settings.present?
