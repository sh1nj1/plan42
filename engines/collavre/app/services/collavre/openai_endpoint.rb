# frozen_string_literal: true

require "uri"

module Collavre
  # Shared credentials may only be used with the official OpenAI API endpoint.
  module OpenaiEndpoint
    DEFAULT_BASE_URL = "https://api.openai.com/v1"

    def self.api_key(base_url:, api_key:)
      api_key.presence || (IntegrationSettings.fetch(:openai_api_key) if official?(base_url))
    end

    def self.official?(base_url)
      uri = URI.parse(base_url.presence || DEFAULT_BASE_URL)
      default_uri = URI.parse(DEFAULT_BASE_URL)
      uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank? &&
        uri.scheme.to_s.downcase == default_uri.scheme && uri.host.to_s.downcase == default_uri.host &&
        uri.port == default_uri.port && uri.path.to_s.sub(%r{/+\z}, "") == default_uri.path
    rescue URI::InvalidURIError
      false
    end
  end
end
