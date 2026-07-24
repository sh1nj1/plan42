module Mcp
  class DiscoveryController < ApplicationController
    # CSRF protection is skipped because these are read-only OAuth/MCP discovery endpoints
    # that must be publicly accessible without session state. MCP clients and OAuth libraries
    # need to fetch these metadata endpoints before establishing any session.
    # See RFC 8414 (OAuth 2.0 Authorization Server Metadata) for spec details.
    skip_before_action :verify_authenticity_token

    # These endpoints serve public OAuth/MCP discovery metadata and must be accessible
    # without authentication per RFC 8414 and MCP specification requirements.
    allow_unauthenticated_access

    RATE_LIMIT_PER_MINUTE = 60

    rate_limit to: RATE_LIMIT_PER_MINUTE, within: 1.minute, with: -> {
      render json: { error: I18n.t("mcp.discovery.rate_limit_exceeded") },
             status: :too_many_requests
    }

    def oauth_protected_resource
      render json: {
        resource: mcp_url_base,
        authorization_servers: [ root_url.chomp("/") ],
        scopes_supported: [ "public" ],
        bearer_methods_supported: [ "header" ]
      }
    end

    def oauth_authorization_server
      render json: {
        issuer: root_url.chomp("/"),
        authorization_endpoint: oauth_authorization_url,
        token_endpoint: oauth_token_url,
        scopes_supported: [ "public" ],
        response_types_supported: [ "code" ],
        grant_types_supported: [ "authorization_code", "refresh_token", "client_credentials" ]
      }
    end

    private

    def mcp_url_base
      "#{root_url.chomp('/')}/mcp"
    end
  end
end
