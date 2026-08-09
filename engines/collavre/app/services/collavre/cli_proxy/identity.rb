# frozen_string_literal: true

require "openssl"

module Collavre
  module CliProxy
    class Identity
      HEADER_NAMES = {
        tenant: "X-CLI-Proxy-Tenant-ID",
        user: "X-CLI-Proxy-User-ID",
        workspace: "X-CLI-Proxy-Workspace-ID",
        timestamp: "X-CLI-Proxy-Identity-Timestamp",
        signature: "X-CLI-Proxy-Identity-Signature"
      }.freeze

      # The workspace header is part of the signed payload. Signing it outside
      # the HMAC would let anyone holding a completion key retarget the request
      # at another workspace of the same user.
      PAYLOAD_VERSION = "v2"

      def self.headers(gateway:, workspace:, method:, path:, at: Time.current)
        secret = gateway.identity_secret.to_s
        return {} if secret.blank?

        timestamp = at.to_i.to_s
        payload = [
          PAYLOAD_VERSION,
          method.to_s.upcase,
          path,
          timestamp,
          gateway.tenant_id,
          workspace.proxy_credential_id,
          workspace.proxy_workspace_id
        ].join("\n")
        signature = OpenSSL::HMAC.hexdigest("SHA256", secret, payload)

        {
          HEADER_NAMES[:tenant] => gateway.tenant_id,
          HEADER_NAMES[:user] => workspace.proxy_credential_id,
          HEADER_NAMES[:workspace] => workspace.proxy_workspace_id,
          HEADER_NAMES[:timestamp] => timestamp,
          HEADER_NAMES[:signature] => signature
        }
      end
    end
  end
end
