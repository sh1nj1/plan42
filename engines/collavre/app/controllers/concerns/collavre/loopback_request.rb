# frozen_string_literal: true

module Collavre
  module LoopbackRequest
    extend ActiveSupport::Concern

    private

    # Only trust the socket peer; forwarded headers may be forged by LAN clients.
    def request_from_loopback?
      addr = IPAddr.new(request.remote_addr.to_s)
      addr = addr.native if addr.respond_to?(:ipv4_mapped?) && addr.ipv4_mapped?
      addr.loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    def require_loopback!
      return true if request_from_loopback?

      head :forbidden
      false
    end

    def require_desktop_mode!
      return true if Rails.application.config.x.desktop_proxy_setup == true

      head :not_found
      false
    end
  end
end
