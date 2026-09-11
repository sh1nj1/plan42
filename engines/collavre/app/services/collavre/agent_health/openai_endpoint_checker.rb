# frozen_string_literal: true

require "uri"

module Collavre
  module AgentHealth
    # Verifies only OpenAI-compatible endpoint reachability and authentication.
    # It deliberately avoids completion requests, which can incur cost or have
    # provider-specific side effects.
    class OpenaiEndpointChecker
      DEFAULT_BASE_URL = "https://api.openai.com/v1"
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 8
      REQUEST_TIMEOUT = OPEN_TIMEOUT + READ_TIMEOUT
      MAX_RESPONSE_BYTES = 64 * 1024

      class InvalidEndpoint < StandardError; end

      def initialize(agent:, client: nil)
        @agent = agent
        @client = client || HttpClient.new(
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
          request_timeout: REQUEST_TIMEOUT,
          max_response_bytes: MAX_RESPONSE_BYTES,
          endpoint_policy: endpoint_policy
        )
      end

      def call
        response = @client.get(models_url, headers: request_headers)
        result_for(response)
      rescue InvalidEndpoint, CliProxy::EndpointPolicy::UnsafeEndpoint
        Result.new(status: :offline, error: "invalid_endpoint")
      rescue HttpClient::ConnectionError
        Result.new(status: :offline, error: "connection_failed")
      rescue HttpClient::ResponseTooLarge
        Result.new(status: :unknown, error: "response_too_large")
      end

      private

      def models_url
        uri = URI.parse(@agent.gateway_url.presence || DEFAULT_BASE_URL)
        valid = uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?
        raise InvalidEndpoint unless valid

        base_path = uri.path.to_s.sub(%r{/+\z}, "")
        uri.path = base_path.end_with?("/models") ? base_path : "#{base_path}/models"
        uri.to_s
      rescue URI::InvalidURIError
        raise InvalidEndpoint
      end

      def request_headers
        headers = { "Accept" => "application/json" }
        api_key = @agent.llm_api_key.presence
        api_key ||= IntegrationSettings.fetch(:openai_api_key) if official_endpoint?
        headers["Authorization"] = "Bearer #{api_key}" if api_key.present?
        headers
      end

      def official_endpoint?
        uri = URI.parse(@agent.gateway_url.presence || DEFAULT_BASE_URL)
        default_uri = URI.parse(DEFAULT_BASE_URL)
        uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank? &&
          uri.scheme.to_s.downcase == default_uri.scheme && uri.host.to_s.downcase == default_uri.host &&
          uri.port == default_uri.port && uri.path.to_s.sub(%r{/+\z}, "") == default_uri.path
      rescue URI::InvalidURIError
        false
      end

      def endpoint_policy
        return if @agent.creator&.system_admin?

        CliProxy::EndpointPolicy.new
      end

      def result_for(response)
        case response.code
        when 200..299
          Result.new(status: :online)
        when 401, 403
          Result.new(status: :offline, error: "authentication_failed")
        when 404, 405
          Result.new(status: :unknown, error: "models_endpoint_unsupported")
        when 408, 425, 429, 500..599
          Result.new(status: :offline, error: "http_#{response.code}")
        else
          Result.new(status: :unknown, error: "http_#{response.code}")
        end
      end
    end
  end
end
