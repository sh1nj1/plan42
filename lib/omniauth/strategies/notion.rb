require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Notion < OmniAuth::Strategies::OAuth2
      # Give your strategy a name
      option :name, "notion"

      # Notion OAuth endpoints
      option :client_options, {
        site: "https://api.notion.com",
        authorize_url: "https://api.notion.com/v1/oauth/authorize",
        token_url: "https://api.notion.com/v1/oauth/token"
      }

      # Default scope
      option :scope, "read write"

      # Define the user info endpoint
      def user_info
        @user_info ||= access_token.get("/v1/users/me").parsed
      end

      # Map the returned data to a format OmniAuth expects
      uid { user_info["bot"]["owner"]["user"]["id"] }

      info do
        {
          workspace_name: user_info["workspace_name"],
          workspace_id: user_info["workspace_id"],
          bot_id: user_info["bot"]["owner"]["user"]["id"]
        }
      end

      extra do
        {
          "raw_info" => user_info
        }
      end

      # Handle the callback phase
      def callback_phase
        begin
          super
        rescue => e
          Rails.logger.error "Notion OAuth callback error: #{e.message}"
          fail!(:invalid_credentials, e)
        end
      end

      # Custom token request to handle Notion's requirements
      def build_access_token
        verifier = request.params["code"]
        client.auth_code.get_token(
          verifier,
          {
            redirect_uri: callback_url,
            headers: {
              "Authorization" => "Basic #{Base64.strict_encode64("#{options.client_id}:#{options.client_secret}")}",
              "Content-Type" => "application/json"
            }
          }.merge(token_params.to_hash(:symbolize_keys => true))
        )
      end
    end
  end
end
