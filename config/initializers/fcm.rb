if ENV["FCM_SERVER_KEY"].present?
  Rails.application.config.x.fcm_client = FCM.new(ENV.fetch("FCM_SERVER_KEY"))
end
