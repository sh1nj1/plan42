require "test_helper"

class QuotaClientTest < ActiveSupport::TestCase
  test "CLI proxy quota raises a recoverable error instead of a final AI error reply" do
    client = Collavre::AiClient.new(vendor: "cli_proxy", model: "test", system_prompt: "", log_interactions: false)
    response = Faraday::Response.new(status: 400, body: { "error" => { "code" => "insufficient_quota" } })
    conversation = Object.new
    conversation.define_singleton_method(:complete) { raise RubyLLM::Error.new(response) }
    conversation.define_singleton_method(:messages) { [] }
    conversation.define_singleton_method(:tools) { [] }
    deltas = []
    client.stub(:build_conversation, conversation) do
      assert_raises(Collavre::Quota::ExceededError) { client.chat([]) { |delta| deltas << delta } }
    end
    assert_empty deltas
    assert client.last_handoff_failed?
  end

  test "ordinary provider billing quota keeps the existing error path" do
    client = Collavre::AiClient.new(vendor: "openai", model: "test", system_prompt: "", log_interactions: false)
    response = Faraday::Response.new(status: 429, body: { "error" => { "code" => "insufficient_quota" } })
    conversation = Object.new
    conversation.define_singleton_method(:complete) { raise RubyLLM::Error.new(response) }
    conversation.define_singleton_method(:messages) { [] }
    conversation.define_singleton_method(:tools) { [] }
    deltas = []
    client.stub(:build_conversation, conversation) { assert_nil client.chat([]) { |delta| deltas << delta } }
    assert_match "AI Error", deltas.join
  end
end
