require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Notion < OmniAuth::Strategies::OAuth2
      option :name, "notion"

      option :client_options, {
        site: "https://api.notion.com",
        authorize_url: "/v1/oauth/authorize",
        token_url: "/v1/oauth/token",
        auth_scheme: :basic_auth
      }

      # Notion requires owner=user parameter for user-level access
      option :authorize_params, {
        owner: "user"
      }

      uid { raw_info["owner"]["user"]["id"] }

      info do
        {
          name: raw_info["workspace_name"],
          workspace_id: raw_info["workspace_id"],
          workspace_name: raw_info["workspace_name"],
          workspace_icon: raw_info["workspace_icon"],
          bot_id: raw_info["bot_id"]
        }
      end

      extra do
        { raw_info: raw_info }
      end

      def raw_info
        @raw_info ||= access_token.response.parsed
      end

      # Notion returns user info in the token response, so no separate API call needed
      def callback_phase
        super
      end
    end
  end
end
