module CollavreSlack
  class SlackEventsController < ApplicationController
    allow_unauthenticated_access only: :create
    skip_forgery_protection only: :create

    def create
      body = request.raw_post
      payload = JSON.parse(body, symbolize_names: true)

      # Handle URL verification challenge first (needed for initial Slack app setup)
      # Slack sends a signed request, but we allow this through to complete setup
      if payload[:type] == "url_verification"
        render json: { challenge: payload[:challenge] }
        return
      end

      # For all other events, validate the signature
      unless valid_signature?(body)
        Rails.logger.warn("[SlackEvents] Invalid signature for event type: #{payload[:type]}")
        render json: { error: "Invalid signature" }, status: :unauthorized
        return
      end

      handler = SlackEventHandler.new(payload: payload)
      normalized = handler.call

      if normalized
        case normalized[:type]
        when :message
          SlackInboundMessageJob.perform_later(normalized)
        when :reaction_added, :reaction_removed
          SlackInboundReactionJob.perform_later(normalized)
        when :message_updated
          SlackInboundMessageUpdateJob.perform_later(normalized)
        when :message_deleted
          SlackInboundMessageDeleteJob.perform_later(normalized)
        end
      end

      head :ok
    end

    private

    def valid_signature?(body)
      return false if signing_secret.blank?

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
