# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "uri"

module Collavre
  module CliProxy
    class EndpointPolicy
      class UnsafeEndpoint < StandardError; end

      DISALLOWED_RANGES = [
        IPAddr.new("0.0.0.0/8"),
        IPAddr.new("10.0.0.0/8"),
        IPAddr.new("100.64.0.0/10"),
        IPAddr.new("127.0.0.0/8"),
        IPAddr.new("169.254.0.0/16"),
        IPAddr.new("172.16.0.0/12"),
        IPAddr.new("192.0.0.0/24"),
        IPAddr.new("192.0.2.0/24"),
        IPAddr.new("192.168.0.0/16"),
        IPAddr.new("198.18.0.0/15"),
        IPAddr.new("198.51.100.0/24"),
        IPAddr.new("203.0.113.0/24"),
        IPAddr.new("224.0.0.0/4"),
        IPAddr.new("240.0.0.0/4"),
        IPAddr.new("::/128"),
        IPAddr.new("::1/128"),
        IPAddr.new("100::/64"),
        IPAddr.new("2001:db8::/32"),
        IPAddr.new("fc00::/7"),
        IPAddr.new("fe80::/10"),
        IPAddr.new("ff00::/8")
      ].freeze

      def initialize(resolver: Resolv)
        @resolver = resolver
      end

      def resolve!(url)
        uri = parsed_https_url!(url)

        addresses = @resolver.getaddresses(uri.hostname).uniq
        raise UnsafeEndpoint if addresses.empty? || addresses.any? { |address| unsafe_ip?(address) }

        addresses
      rescue URI::InvalidURIError, Resolv::ResolvError, SocketError, ArgumentError
        raise UnsafeEndpoint
      end

      def safe_literal?(url)
        uri = parsed_https_url!(url)

        literal = IPAddr.new(uri.hostname)
        !unsafe_ip?(literal)
      rescue IPAddr::InvalidAddressError
        !uri.hostname.casecmp("localhost").zero? && !uri.hostname.downcase.end_with?(".localhost")
      rescue URI::InvalidURIError, UnsafeEndpoint
        false
      end

      private

      def parsed_https_url!(url)
        uri = url.is_a?(URI) ? url : URI.parse(url.to_s)
        raise UnsafeEndpoint unless uri.is_a?(URI::HTTPS) && uri.hostname.present?
        raise UnsafeEndpoint if uri.userinfo.present? || uri.query.present? || uri.fragment.present?

        uri
      end

      def unsafe_ip?(address)
        ip = address.is_a?(IPAddr) ? address : IPAddr.new(address)
        ip = ip.native if ip.ipv4_mapped?
        DISALLOWED_RANGES.any? { |range| range.include?(ip) }
      rescue IPAddr::InvalidAddressError
        true
      end
    end
  end
end
