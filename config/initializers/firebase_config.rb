firebase_settings = {
  apiKey: Rails.application.credentials.dig(:firebase, :api_key) || ENV["FIREBASE_API_KEY"],
  authDomain: Rails.application.credentials.dig(:firebase, :auth_domain) || ENV["FIREBASE_AUTH_DOMAIN"],
  projectId: Rails.application.credentials.dig(:firebase, :project_id) || ENV["FIREBASE_PROJECT_ID"],
  appId: Rails.application.credentials.dig(:firebase, :app_id) || ENV["FIREBASE_APP_ID"],
  messagingSenderId: Rails.application.credentials.dig(:fcm, :sender_id) || ENV["FCM_SENDER_ID"],
  vapidKey: Rails.application.credentials.dig(:fcm, :vapid_key) || ENV["FCM_VAPID_KEY"]
}.compact

Rails.application.config.x.firebase_config = firebase_settings if firebase_settings.present?
