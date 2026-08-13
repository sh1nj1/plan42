# frozen_string_literal: true

module Collavre
  # Authenticates the Rails child to the native shell before its webview is
  # navigated to the local server. The secret is generated per launch by Tauri
  # and exists only in this child process environment.
  class DesktopSidecarHealthController < ActionController::API
    def show
      return unless require_loopback!

      secret = ENV.fetch("COLLAVRE_DESKTOP_SIDECAR_SECRET", "")
      return head :not_found if secret.blank?

      challenge = params.require(:challenge)
      digest = OpenSSL::HMAC.digest("SHA256", secret, challenge)
      render plain: Base64.urlsafe_encode64(digest, padding: false), content_type: "text/plain"
    rescue ActionController::ParameterMissing
      head :bad_request
    end

    private

    def require_loopback!
      addr = IPAddr.new(request.remote_addr.to_s)
      addr = addr.native if addr.respond_to?(:ipv4_mapped?) && addr.ipv4_mapped?
      return true if addr.loopback?

      head :forbidden
      false
    rescue IPAddr::InvalidAddressError
      head :forbidden
      false
    end
  end
end
