server_key = Rails.application.credentials.dig(:fcm, :server_key) || ENV["FCM_SERVER_KEY"]

if server_key.present?
  Rails.application.config.x.fcm_client = FCM.new(server_key)
end
