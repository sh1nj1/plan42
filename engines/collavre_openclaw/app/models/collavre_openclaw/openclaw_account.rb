module CollavreOpenclaw
  class OpenclawAccount < ApplicationRecord
    self.table_name = "openclaw_accounts"

    # The user is the AI agent in Collavre
    belongs_to :user, class_name: "::User"

    validates :gateway_url, presence: true
    validates :user_id, uniqueness: true

    encrypts :api_token, deterministic: false

    # Build the full API endpoint URL (OpenAI-compatible)
    def api_endpoint
      uri = URI.parse(gateway_url)
      uri.path = "/v1/chat/completions"
      uri.to_s
    end

    # Callback URL for receiving responses and proactive messages
    def callback_url
      host_options = default_url_options
      return nil if host_options[:host].blank?

      CollavreOpenclaw::Engine.routes.url_helpers.callback_url(
        account_id: id,
        **host_options
      )
    rescue StandardError => e
      Rails.logger.warn("[CollavreOpenclaw] Failed to generate callback URL: #{e.message}")
      nil
    end

    # Alternative callback path (relative, for manual URL construction)
    def callback_path
      "/openclaw/callback/#{id}"
    end

    private

    def default_url_options
      options = Rails.application.config.action_mailer.default_url_options || {}

      # Try multiple sources for host configuration
      host = options[:host]
      host ||= Rails.application.config.action_controller.default_url_options&.dig(:host)
      host ||= ENV["APP_HOST"]
      host ||= ENV["RAILS_HOST"]

      result = { host: host }
      result[:protocol] = options[:protocol] || "https"
      result[:port] = options[:port] if options[:port].present?

      result
    end
  end
end
