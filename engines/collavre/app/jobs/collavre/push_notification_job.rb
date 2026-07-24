module Collavre
class PushNotificationJob < ApplicationJob
  # Comment bodies are unbounded and go out as the notification body verbatim,
  # so FCM rejects the oversized ones permanently — retrying cannot help, the
  # payload is the defect. Two rejections were observed in production: "Message
  # is too large. The maximum is 4K (4096 bytes)." above ~4.8KB, and a bare
  # "INVALID_ARGUMENT: Invalid argument." starting at 2440 bytes. Budget the
  # whole request at half of FCM's documented ceiling, which also sits below the
  # smallest payload FCM has actually refused for us. A notification body is a
  # preview anyway; no shade renders more than a few lines.
  MAX_REQUEST_BYTES = 2048
  ELLIPSIS = "…".freeze
  TITLE = "새 알림".freeze

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
    body = fit_body(token, message, link)
    msg = build_message(token, body, link)
    Rails.logger.info("Sending push to token: #{token} with #{body.bytesize} body bytes and link: #{link}")

    request = Google::Apis::FcmV1::SendMessageRequest.new(message: msg)

    begin
      response = service.send_message("projects/#{project_id}", request)
      Rails.logger.info("✅ Push sent successfully: #{token} #{response.inspect}")
      response
    rescue Google::Apis::ClientError => e
      # A 4xx is about this one registration, not the notification: the endpoint
      # is gone, or that push service refused the payload. Raising would abandon
      # every device queued behind it, which is how one stale subscription used
      # to silence a user's other browsers. Transient errors (auth, 5xx) still
      # propagate so the job retries.
      if invalid_registration_token?(e)
        Rails.logger.warn("⚠️ Removing invalid FCM token: #{token} (#{e.message})")
        Device.where(fcm_token: token).delete_all
      else
        Rails.logger.warn("⚠️ FCM rejected the push for token #{token}: #{e.message}")
      end
      nil
    end
  end

  def build_message(token, body, link)
    Google::Apis::FcmV1::Message.new(
      token: token,
      notification: Google::Apis::FcmV1::Notification.new(title: TITLE, body: body),
      webpush: Google::Apis::FcmV1::WebpushConfig.new(
        fcm_options: Google::Apis::FcmV1::WebpushFcmOptions.new(link: link)
      ),
      data: { path: link }
    )
  end

  # Everything except the body — token, title, link (twice) and the JSON
  # envelope — is fixed, so measure it and spend whatever is left on the body.
  # Deriving the budget instead of hardcoding a character count keeps the cap
  # correct when a long deep link crowds out the text.
  def fit_body(token, message, link)
    text = message.to_s
    return text if request_bytesize(token, text, link) <= MAX_REQUEST_BYTES

    budget = MAX_REQUEST_BYTES - request_bytesize(token, "", link) - ELLIPSIS.bytesize
    return ELLIPSIS if budget <= 0

    truncate_bytes(text, budget) + ELLIPSIS
  end

  def request_bytesize(token, body, link)
    Google::Apis::FcmV1::SendMessageRequest
      .new(message: build_message(token, body, link))
      .to_json
      .bytesize
  end

  # byteslice can cut a multi-byte character in half; scrub drops the dangling
  # bytes rather than shipping invalid UTF-8 that FCM would reject in turn.
  def truncate_bytes(text, max_bytes)
    return text if text.bytesize <= max_bytes

    text.byteslice(0, max_bytes).scrub("")
  end

  def invalid_registration_token?(error)
    status_code = error.respond_to?(:status_code) ? error.status_code : nil
    return false unless status_code == 404

    payload = parse_error_body(error.body)
    contains_unregistered_detail?(payload)
  end

  def parse_error_body(body)
    JSON.parse(body) if body.present?
  rescue JSON::ParserError
    nil
  end

  def contains_unregistered_detail?(body)
    details = body&.dig("error", "details")
    Array(details).any? do |detail|
      detail["@type"] == "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
        detail["errorCode"] == "UNREGISTERED"
    end
  end
end
end
