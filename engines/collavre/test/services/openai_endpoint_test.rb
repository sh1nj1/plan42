# frozen_string_literal: true

require "test_helper"

module Collavre
  class OpenaiEndpointTest < ActiveSupport::TestCase
    test "recognizes the default endpoint and equivalent official URLs" do
      [ nil, "", "https://api.openai.com/v1", "https://API.OPENAI.COM/v1",
        "https://api.openai.com:443/v1/" ].each do |url|
        assert OpenaiEndpoint.official?(url), url.inspect
      end
    end

    test "never fetches shared credentials for custom or malformed endpoints" do
      urls = [
        "https://gateway.example.test/v1", "http://api.openai.com/v1",
        "https://api.openai.com:444/v1", "https://api.openai.com/v2",
        "https://api.openai.com.example.test/v1", "https://user@api.openai.com/v1",
        "https://api.openai.com/v1?redirect=evil", "https://api.openai.com/v1#fragment",
        "not a URL", "mailto:test@example.test"
      ]
      IntegrationSettings.stub(:fetch, ->(*) { flunk "Custom endpoints must not fetch shared credentials" }) do
        urls.each do |url|
          assert_not OpenaiEndpoint.official?(url), url
          assert_nil OpenaiEndpoint.api_key(base_url: url, api_key: nil), url
          assert_equal "agent-key", OpenaiEndpoint.api_key(base_url: url, api_key: "agent-key")
        end
      end
    end

    test "prefers the agent key and tolerates missing integration credentials" do
      IntegrationSettings.stub(:fetch, nil) do
        assert_nil OpenaiEndpoint.api_key(base_url: nil, api_key: nil)
        assert_equal "agent-key", OpenaiEndpoint.api_key(base_url: nil, api_key: "agent-key")
      end
    end
  end
end
