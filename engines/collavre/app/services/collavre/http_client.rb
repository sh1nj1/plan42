# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Collavre
  # Thin, dependency-free HTTP wrapper over Net::HTTP shared across engines.
  #
  # It centralizes timeout configuration, TLS negotiation and transport-error
  # handling so vendor engines no longer each hand-roll their own Net::HTTP /
  # HTTParty / Faraday setup. Callers keep full ownership of their own response
  # parsing and domain error mapping — this wrapper only performs the request and
  # returns a small Response value object.
  #
  # Transport-layer failures (DNS, connection refused/reset, TLS handshake,
  # open/read timeouts) are wrapped in Collavre::HttpClient::ConnectionError so a
  # caller can rescue a single, stable error type regardless of the underlying
  # exception class.
  class HttpClient
    class Error < StandardError; end
    class ConnectionError < Error; end

    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 30

    # Transport-level exceptions that occur before any HTTP response exists.
    TRANSPORT_ERRORS = [
      SocketError, SystemCallError, Timeout::Error, IOError,
      OpenSSL::SSL::SSLError, Net::OpenTimeout, Net::ReadTimeout
    ].freeze

    REQUEST_CLASSES = {
      get: Net::HTTP::Get,
      post: Net::HTTP::Post,
      patch: Net::HTTP::Patch,
      put: Net::HTTP::Put,
      delete: Net::HTTP::Delete
    }.freeze

    # A minimal, read-only view over a Net::HTTP response.
    class Response
      attr_reader :code, :message, :body, :headers

      def initialize(net_response)
        @net_response = net_response
        @code = net_response.code.to_i
        @message = net_response.message
        @body = net_response.body
        @headers = net_response.to_hash
      end

      def success?
        @net_response.is_a?(Net::HTTPSuccess)
      end

      # Parse the response body as JSON, or nil when the body is empty.
      def json
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      end
    end

    def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, default_headers: {},
                   endpoint_policy: nil)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @default_headers = default_headers
      @endpoint_policy = endpoint_policy
    end

    def get(url, headers: {})
      request(:get, url, headers: headers)
    end

    def post(url, body: nil, headers: {})
      request(:post, url, body: body, headers: headers)
    end

    def patch(url, body: nil, headers: {})
      request(:patch, url, body: body, headers: headers)
    end

    def put(url, body: nil, headers: {})
      request(:put, url, body: body, headers: headers)
    end

    def delete(url, headers: {})
      request(:delete, url, headers: headers)
    end

    private

    def request(method, url, body: nil, headers: {})
      uri = URI.parse(url)
      http = build_connection(uri)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      req = build_request(method, uri, body, headers)
      Response.new(http.request(req))
    rescue *TRANSPORT_ERRORS => e
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    def build_connection(uri)
      return Net::HTTP.new(uri.host, uri.port) unless @endpoint_policy

      pinned_ip = @endpoint_policy.resolve!(uri).first
      Net::HTTP.new(uri.host, uri.port, nil).tap { |http| http.ipaddr = pinned_ip }
    end

    def build_request(method, uri, body, headers)
      path = uri.path.presence || "/"
      path = "#{path}?#{uri.query}" if uri.query.present?

      request_class = REQUEST_CLASSES.fetch(method) do
        raise ArgumentError, "Unsupported HTTP method: #{method}"
      end
      req = request_class.new(path)
      @default_headers.merge(headers).each { |key, value| req[key] = value }
      req.body = body unless body.nil?
      req
    end
  end
end
