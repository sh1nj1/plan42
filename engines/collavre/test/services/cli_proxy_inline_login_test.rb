require "test_helper"

class CliProxyInlineLoginTest < ActiveSupport::TestCase
  setup do
    @workspace = Struct.new(:id).new(42)
    @body = { "error" => { "code" => "engine_unauthenticated", "engine" => "codex", "type" => "invalid_request_error", "message" => "Login required" } }
  end

  test "classifies structured HTTP and SSE errors and rejects unrelated or malformed errors" do
    [ @body, @body.to_json ].each do |body|
      response = Struct.new(:status, :body).new(401, body)
      error = Collavre::CliProxy::EngineUnauthenticatedError.from_response(RubyLLM::UnauthorizedError.new(response), workspace: @workspace)
      assert_equal "codex", error.engine
      assert_equal @workspace, error.workspace
    end
    [ "bad json", [], { "error" => "Login required" }, { "error" => { "code" => "invalid_api_key" } },
      { "error" => { "code" => "engine_unauthenticated", "engine" => "../../bad" } } ].each do |body|
      response = Struct.new(:body).new(body)
      assert_nil Collavre::CliProxy::EngineUnauthenticatedError.from_response(RubyLLM::Error.new(response), workspace: @workspace)
    end
    assert_nil Collavre::CliProxy::EngineUnauthenticatedError.from_response(StandardError.new("Login required"), workspace: @workspace)
  end

  test "real RubyLLM SSE parser preserves machine code across fragmented data events" do
    config = RubyLLM.config.dup
    config.openai_api_key = "test-key"
    provider = RubyLLM::Providers::OpenAI.new(config)
    handler = provider.send(:handle_stream) { flunk "error must not be a completion chunk" }
    env = Faraday::Env.from(status: 200)
    stream = "data: #{@body.to_json}\n\n"
    error = assert_raises(RubyLLM::BadRequestError) do
      handler.call(stream[0...19], 19, env)
      handler.call(stream[19..], stream.bytesize, env)
    end
    assert_equal 400, error.response.status
    classified = Collavre::CliProxy::EngineUnauthenticatedError.from_response(error, workspace: @workspace)
    assert_equal "codex", classified.engine
  end

  test "AiClient logs the error class before raising a login requirement without exposing provider content" do
    secret = "sensitive-provider-message"
    response = Struct.new(:status, :body).new(401, @body)
    conversation = Object.new
    conversation.define_singleton_method(:complete) { raise RubyLLM::UnauthorizedError.new(response, secret) }
    client = Collavre::AiClient.new(vendor: "cli_proxy", model: "paperclip/codex_local", system_prompt: "", log_interactions: false)
    client.instance_variable_set(:@cli_proxy_identity, { workspace: @workspace })
    messages = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| messages << message }

    Rails.stub(:logger, logger) do
      client.stub(:build_conversation, conversation) do
        client.stub(:add_messages, nil) do
          error = assert_raises(Collavre::CliProxy::EngineUnauthenticatedError) { client.chat([]) }
          assert_equal "codex", error.engine
          assert_equal @workspace, error.workspace
          assert_equal [ "AI Client error: [RubyLLM::UnauthorizedError]" ], messages
          assert_not_includes messages.join, secret
        end
      end
    end
  end

  test "AiClient raises login requirement only for a configured CLI proxy and keeps handoff evidence" do
    response = Struct.new(:status, :body).new(401, @body)
    conversation = Object.new
    conversation.define_singleton_method(:complete) { raise RubyLLM::UnauthorizedError.new(response, "Login required") }
    [ "cli_proxy", "openai" ].each do |vendor|
      client = Collavre::AiClient.new(vendor: vendor, model: "paperclip/codex_local", system_prompt: "", log_interactions: false)
      client.instance_variable_set(:@cli_proxy_identity, { workspace: @workspace })
      deltas = []
      client.stub(:build_conversation, conversation) do
        client.stub(:add_messages, nil) do
          if vendor == "cli_proxy"
            assert_raises(Collavre::CliProxy::EngineUnauthenticatedError) { client.chat([]) { |delta| deltas << delta } }
            assert_empty deltas
          else
            assert_nil client.chat([]) { |delta| deltas << delta }
            assert_includes deltas.join, "AI Error"
          end
        end
      end
      assert client.last_handoff_failed?
      assert_not client.handed_off?
    end
  end
end
