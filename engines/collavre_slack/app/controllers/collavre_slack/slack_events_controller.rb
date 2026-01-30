module CollavreSlack
  class SlackEventsController < ApplicationController
    allow_unauthenticated_access only: :create
    skip_forgery_protection only: :create

    def create
      body = request.raw_post
      unless valid_signature?(body)
        render json: { error: "Invalid signature" }, status: :unauthorized
        return
      end

      payload = JSON.parse(body, symbolize_names: true)

      if payload[:type] == "url_verification"
        render json: { challenge: payload[:challenge] }
        return
      end

      handler = SlackEventHandler.new(payload: payload)
      normalized = handler.call

      SlackInboundMessageJob.perform_later(normalized) if normalized

      head :ok
    end

    private

    def valid_signature?(body)
      timestamp = request.headers["X-Slack-Request-Timestamp"].to_s
      signature = request.headers["X-Slack-Signature"].to_s
      return false if timestamp.blank? || signature.blank?

      return false if (Time.now.to_i - timestamp.to_i).abs > 300

      base = "v0:#{timestamp}:#{body}"
      expected = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", signing_secret, base)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def signing_secret
      CollavreSlack.config.signing_secret
    end
  end
end
