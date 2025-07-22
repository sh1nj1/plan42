class PushNotificationJob < ApplicationJob
  queue_as :default

  def perform(user_id, message:, link: nil)
    tokens = Device.where(user_id: user_id).pluck(:fcm_token)
    return if tokens.empty?

    service = Rails.application.config.x.fcm_service
    project_id = Rails.application.config.x.fcm_project_id

    if service && project_id
      tokens.each do |token|
        send_v1(service, project_id, token, message, link)
      end
    elsif (client = Rails.application.config.x.fcm_client)
      client.send(tokens, {
        notification: {
          title: "새 알림",
          body: message,
          click_action: link
        }
      })
    end
  end

  private

  def send_v1(service, project_id, token, message, link)
    notification = Google::Apis::FcmV1::Notification.new(
      title: "새 알림",
      body: message
    )

    webpush = Google::Apis::FcmV1::WebpushConfig.new(
      fcm_options: Google::Apis::FcmV1::WebpushFcmOptions.new(link: link)
    )

    msg = Google::Apis::FcmV1::Message.new(
      token: token,
      notification: notification,
      webpush: webpush
    )

    request = Google::Apis::FcmV1::SendMessageRequest.new(message: msg)
    service.send_message("projects/#{project_id}", request)
  end
end
