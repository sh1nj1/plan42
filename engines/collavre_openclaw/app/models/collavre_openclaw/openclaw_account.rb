module CollavreOpenclaw
  class OpenclawAccount < ApplicationRecord
    self.table_name = "openclaw_accounts"

    # The user is the AI agent in Collavre
    belongs_to :user, class_name: "::User"

    # Pending callbacks for async responses - cascade delete when account is deleted
    has_many :pending_callbacks,
             class_name: "CollavreOpenclaw::PendingCallback",
             dependent: :destroy

    validates :gateway_url, presence: true
    validates :user_id, uniqueness: true

    encrypts :api_key, deterministic: false

    # Skip updating api_key if empty string (preserve existing token)
    # Note: nil is allowed (for clear_token!), only empty string "" is rejected
    before_validation :preserve_existing_token

    def preserve_existing_token
      if persisted? && api_key_changed? && api_key == ""
        restore_attribute!(:api_key)
      end
    end

    # Check if token is configured (without revealing the actual value)
    def token_configured?
      api_key.present?
    end

    # Clear the API token
    def clear_token!
      update!(api_key: nil)
    end

    # Test connection to OpenClaw gateway
    # Returns { success: true/false, message: "...", details: "..." }
    def test_connection
      require "faraday"
      require "json"

      return { success: false, message: "Gateway URL not configured" } if gateway_url.blank?

      begin
        connection = Faraday.new do |builder|
          builder.options.timeout = 10
          builder.options.open_timeout = 5
          builder.adapter Faraday.default_adapter
        end

        # Try to make a simple request to the gateway
        # First try the health endpoint, then fall back to a minimal chat request
        health_url = URI.parse(gateway_url)
        health_url.path = "/health"

        response = connection.get(health_url.to_s) do |req|
          req.headers["Authorization"] = "Bearer #{api_key}" if api_key.present?
        end

        if response.success?
          return { success: true, message: "Connection successful", details: "Gateway is reachable" }
        end

        # If health check fails, try a minimal chat completions request
        test_payload = {
          model: "openclaw",
          messages: [ { role: "user", content: "ping" } ],
          max_tokens: 1
        }

        response = connection.post(api_endpoint) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["Authorization"] = "Bearer #{api_key}" if api_key.present?
          req.body = test_payload.to_json
        end

        case response.status
        when 200..299
          { success: true, message: "Connection successful", details: "API endpoint is responding" }
        when 401
          { success: false, message: "Authentication failed", details: "Invalid or missing API token" }
        when 403
          { success: false, message: "Access denied", details: "API token does not have permission" }
        when 404
          { success: false, message: "Endpoint not found", details: "The gateway URL may be incorrect" }
        when 500..599
          { success: false, message: "Server error", details: "The gateway returned an error (#{response.status})" }
        else
          { success: false, message: "Unexpected response", details: "HTTP #{response.status}" }
        end
      rescue Faraday::ConnectionFailed => e
        { success: false, message: "Connection failed", details: "Could not connect to gateway: #{e.message}" }
      rescue Faraday::TimeoutError
        { success: false, message: "Connection timeout", details: "Gateway did not respond in time" }
      rescue URI::InvalidURIError
        { success: false, message: "Invalid URL", details: "The gateway URL format is invalid" }
      rescue StandardError => e
        { success: false, message: "Error", details: e.message }
      end
    end

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
