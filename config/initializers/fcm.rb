server_key = Rails.application.credentials.dig(:fcm, :server_key) || ENV["FCM_SERVER_KEY"]
project_id = Rails.application.credentials.dig(:firebase, :project_id)

if project_id.present?
  require "google/apis/fcm_v1"
  scope = Google::Apis::FcmV1::AUTH_FIREBASE_MESSAGING

  service = Google::Apis::FcmV1::FirebaseCloudMessagingService.new
  service.authorization = Google::Auth.get_application_default(scope)

  Rails.application.config.x.fcm_service = service
  Rails.application.config.x.fcm_project_id = project_id
end

if server_key.present?
  Rails.application.config.x.fcm_client = FCM.new(server_key)
end
