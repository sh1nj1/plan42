# frozen_string_literal: true

require "fast_mcp"

module Collavre
  module McpDiscoveryAccess
    private

    # FastMcp caches filtered servers by request headers. Grants can change
    # while a token remains valid, so discovery must rebuild its view each time.
    def get_server_for_request(request, env)
      env[FastMcp::Transports::RackTransport::SERVER_ENV_KEY] || @server.create_filtered_copy(request)
    end
  end
end

FastMcp::Transports::RackTransport.prepend(Collavre::McpDiscoveryAccess)
