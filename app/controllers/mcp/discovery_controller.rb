module Mcp
  class DiscoveryController < ApplicationController
    skip_before_action :verify_authenticity_token
    allow_unauthenticated_access

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
