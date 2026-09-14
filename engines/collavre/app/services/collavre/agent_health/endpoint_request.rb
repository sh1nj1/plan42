# frozen_string_literal: true

require "json"

module Collavre
  module AgentHealth
    # Request settings for the direct RubyLLM providers. Native providers ignore
    # gateway_url, just as AiClient does; only OpenAI supports per-agent URLs.
    class EndpointRequest
      VENDORS = %w[openai google gemini anthropic].freeze

      def initialize(agent:)
        @agent = agent
        @vendor = agent.llm_vendor.to_s.strip.downcase
      end

      def base_url
        case @vendor
        when "google", "gemini"
          RubyLLM.config.gemini_api_base || "https://generativelanguage.googleapis.com/v1beta"
        when "anthropic"
          "#{(RubyLLM.config.anthropic_api_base || 'https://api.anthropic.com').delete_suffix('/')}/v1"
        else
          @agent.gateway_url.presence || OpenaiEndpoint::DEFAULT_BASE_URL
        end
      end

      def headers
        authentication = case @vendor
        when "google", "gemini"
          { "x-goog-api-key" => vendor_api_key(:gemini_api_key) }
        when "anthropic"
          { "x-api-key" => vendor_api_key(:anthropic_api_key), "anthropic-version" => "2023-06-01" }
        else
          key = OpenaiEndpoint.api_key(base_url: @agent.gateway_url, api_key: @agent.llm_api_key)
          key.present? ? { "Authorization" => "Bearer #{key}" } : {}
        end
        { "Accept" => "application/json" }.merge(authentication.compact)
      end

      def authentication_failed?(response)
        return true if [ 401, 403 ].include?(response.code)
        return false unless %w[google gemini].include?(@vendor) && response.code == 400

        invalid_google_api_key?(response.body)
      end

      private

      def invalid_google_api_key?(body)
        payload = JSON.parse(body.to_s, symbolize_names: true)
        return false unless payload in { error: { details: Array => details } }

        details.any? { |detail| detail in { reason: "API_KEY_INVALID" } }
      rescue JSON::ParserError
        false
      end

      def vendor_api_key(setting)
        @agent.llm_api_key.presence || IntegrationSettings.fetch(setting)
      end
    end
  end
end
