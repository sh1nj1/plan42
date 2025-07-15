class PushNotificationJob < ApplicationJob
  queue_as :default

  def perform(user_id, message:, link: nil)
    client = Rails.application.config.x.fcm_client
    return unless client

    tokens = Device.where(user_id: user_id).pluck(:fcm_token)
    return if tokens.empty?

    client.send(tokens, {
      notification: {
        title: "새 알림",
        body: message,
        click_action: link
      }
    })
  end
end
