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
      payload = {
        notification: {
          title: "새 알림",
          body: message,
          click_action: link
        }
      }
      payload[:data] = { path: link } if link
      client.send(tokens, payload)
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

    data = link ? { path: link } : nil

    msg = Google::Apis::FcmV1::Message.new(
      token: token,
      notification: notification,
      webpush: webpush,
      data: data
    )

    request = Google::Apis::FcmV1::SendMessageRequest.new(message: msg)
    response = service.send_message("projects/#{project_id}", request)
    Rails.logger.info("✅ Push sent successfully: #{response.inspect}")
    response
  end
end
