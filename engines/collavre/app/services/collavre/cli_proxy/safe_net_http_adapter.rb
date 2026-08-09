# frozen_string_literal: true

require "faraday/net_http"

module Collavre
  module CliProxy
    class SafeNetHttpAdapter < Faraday::Adapter::NetHttp
      def net_http_connection(env)
        uri = env[:url]
        pinned_ip = EndpointPolicy.new.resolve!(uri).first
        port = uri.port || 443

        Net::HTTP.new(uri.hostname, port, nil).tap do |http|
          http.ipaddr = pinned_ip
        end
      end
    end
  end
end
