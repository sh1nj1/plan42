module CollavreOpenclaw
  class OpenclawAccount < ApplicationRecord
    self.table_name = "openclaw_accounts"

    # The user is the AI agent in Collavre
    belongs_to :user, class_name: "::User"

    validates :gateway_url, presence: true
    validates :user_id, uniqueness: true

    encrypts :api_token, deterministic: false

    # Build the full API endpoint URL
    def api_endpoint
      uri = URI.parse(gateway_url)
      uri.path = "/api/v1/chat"
      uri.to_s
    end

    # Webhook URL for receiving responses (if async mode is used)
    def webhook_callback_url
      CollavreOpenclaw::Engine.routes.url_helpers.callback_url(
        account_id: id,
        host: Rails.application.config.action_mailer.default_url_options[:host]
      )
    rescue StandardError
      nil
    end
  end
end
