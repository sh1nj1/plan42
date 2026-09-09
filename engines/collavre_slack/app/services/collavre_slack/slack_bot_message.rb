require "digest"

module CollavreSlack
  class SlackBotMessage
    def initialize(account:, message:)
      @account = account
      @message = message
    end

    def bot?
      @message[:bot_id].present? || @message[:subtype] == "bot_message"
    end

    def own?
      return false unless bot?

      identity = bot_identity
      @message[:bot_id] == identity[:bot_id] ||
        (@message[:user].present? && @message[:user] == identity[:user_id])
    end

    def sender
      # Bots must not be auto-mapped to a person by email or queried with a nil user ID.
      name = @message[:username].presence || @message.dig(:bot_profile, :name).presence || @message[:bot_id]
      { user: nil, slack_display_name: name, slack_email: nil, slack_user_id: @message[:user] }
    end

    private

    def bot_identity
      token_digest = Digest::SHA256.hexdigest(@account.access_token)
      Rails.cache.fetch([ "slack_bot_identity", @account.id, token_digest ], expires_in: 1.hour) do
        response = SlackClient.new(access_token: @account.access_token).auth_test
        # Raise before the webhook is acknowledged so Slack can retry; never cache failures.
        unless response[:ok] && response[:bot_id].present? && response[:user_id].present?
          raise "Unable to resolve Slack bot identity"
        end
        response.slice(:bot_id, :user_id)
      end
    end
  end
end
