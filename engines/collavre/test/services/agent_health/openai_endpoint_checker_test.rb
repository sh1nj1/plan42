# frozen_string_literal: true

require "test_helper"

module Collavre
  module AgentHealth
    class OpenaiEndpointCheckerTest < ActiveSupport::TestCase
      Response = Struct.new(:code, keyword_init: true)

      class RecordingClient
        attr_reader :url, :headers

        def initialize(response: Response.new(code: 200), error: nil)
          @response = response
          @error = error
        end

        def get(url, headers:)
          @url = url
          @headers = headers
          raise @error if @error

          @response
        end
      end

      setup do
        @owner = users(:one)
        @agent = Collavre::User.create!(
          name: "Endpoint Agent",
          email: "endpoint-agent@example.test",
          password: SecureRandom.hex(24),
          llm_vendor: "openai",
          llm_model: "gpt-test",
          llm_api_key: "secret-key",
          gateway_url: "https://gateway.example.test/v1/",
          created_by_id: @owner.id
        )
      end

      test "checks the models endpoint with the configured bearer key" do
        client = RecordingClient.new

        result = OpenaiEndpointChecker.new(agent: @agent, client: client).call

        assert_equal :online, result.status
        assert_nil result.error
        assert_equal "https://gateway.example.test/v1/models", client.url
        assert_equal "Bearer secret-key", client.headers["Authorization"]
        assert_equal "application/json", client.headers["Accept"]
      end

      test "uses the official endpoint and integration key when agent settings are blank" do
        @agent.update!(gateway_url: nil, llm_api_key: nil)
        client = RecordingClient.new

        IntegrationSettings.stub(:fetch, "shared-key") do
          OpenaiEndpointChecker.new(agent: @agent, client: client).call
        end

        assert_equal "https://api.openai.com/v1/models", client.url
        assert_equal "Bearer shared-key", client.headers["Authorization"]
      end

      test "does not send authorization when a keyless endpoint is configured" do
        @agent.update!(llm_api_key: nil)
        client = RecordingClient.new

        IntegrationSettings.stub(:fetch, "shared-key") do
          OpenaiEndpointChecker.new(agent: @agent, client: client).call
        end

        assert_not client.headers.key?("Authorization")
      end

      test "uses the integration key when the official endpoint is configured explicitly" do
        @agent.update!(gateway_url: "https://api.openai.com/v1/", llm_api_key: nil)
        client = RecordingClient.new

        IntegrationSettings.stub(:fetch, "shared-key") do
          OpenaiEndpointChecker.new(agent: @agent, client: client).call
        end

        assert_equal "Bearer shared-key", client.headers["Authorization"]
      end

      test "does not append models twice" do
        @agent.update!(gateway_url: "https://gateway.example.test/v1/models")
        client = RecordingClient.new

        OpenaiEndpointChecker.new(agent: @agent, client: client).call

        assert_equal "https://gateway.example.test/v1/models", client.url
      end

      test "maps HTTP responses without making a completion request" do
        expectations = {
          204 => [ :online, nil ],
          401 => [ :offline, "authentication_failed" ],
          403 => [ :offline, "authentication_failed" ],
          404 => [ :unknown, "models_endpoint_unsupported" ],
          405 => [ :unknown, "models_endpoint_unsupported" ],
          408 => [ :offline, "http_408" ],
          425 => [ :offline, "http_425" ],
          429 => [ :offline, "http_429" ],
          503 => [ :offline, "http_503" ],
          400 => [ :unknown, "http_400" ]
        }

        expectations.each do |code, (status, error)|
          client = RecordingClient.new(response: Response.new(code: code))
          result = OpenaiEndpointChecker.new(agent: @agent, client: client).call

          assert_equal status, result.status, "HTTP #{code}"
          error.nil? ? assert_nil(result.error, "HTTP #{code}") : assert_equal(error, result.error, "HTTP #{code}")
        end
      end

      test "maps transport and oversized response errors" do
        connection = RecordingClient.new(error: HttpClient::ConnectionError.new("secret host failed"))
        oversized = RecordingClient.new(error: HttpClient::ResponseTooLarge.new("too large"))

        assert_equal "connection_failed", OpenaiEndpointChecker.new(agent: @agent, client: connection).call.error
        oversized_result = OpenaiEndpointChecker.new(agent: @agent, client: oversized).call
        assert_equal :unknown, oversized_result.status
        assert_equal "response_too_large", oversized_result.error
      end

      test "rejects malformed and policy-blocked endpoints" do
        @agent.update!(gateway_url: "not a URL")
        assert_equal "invalid_endpoint", OpenaiEndpointChecker.new(agent: @agent).call.error

        non_admin = users(:two)
        @agent.update!(created_by_id: non_admin.id, gateway_url: "http://127.0.0.1:11434/v1")
        assert_equal "invalid_endpoint", OpenaiEndpointChecker.new(agent: @agent).call.error
      end

      test "applies endpoint policy for non-admin owners and bypasses it for administrators" do
        assert_nil OpenaiEndpointChecker.new(agent: @agent, client: RecordingClient.new).send(:endpoint_policy)

        @agent.update!(created_by_id: users(:two).id)
        policy = OpenaiEndpointChecker.new(agent: @agent, client: RecordingClient.new).send(:endpoint_policy)
        assert_instance_of CliProxy::EndpointPolicy, policy
      end
    end
  end
end
