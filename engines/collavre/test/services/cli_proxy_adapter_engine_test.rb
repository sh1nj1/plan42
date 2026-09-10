require "test_helper"

class CliProxyAdapterEngineTest < ActiveSupport::TestCase
  test "maps each adapter onto the engine whose credential its runs spend" do
    assert_equal "claude", Collavre::CliProxy::AdapterEngine.for_model("paperclip/claude_local")
    assert_equal "codex", Collavre::CliProxy::AdapterEngine.for_model("paperclip/codex_local")
    assert_equal "codex_custom", Collavre::CliProxy::AdapterEngine.for_model("paperclip/codex_custom")
  end

  test "ignores the CLI model suffix the adapter forwards" do
    assert_equal "claude", Collavre::CliProxy::AdapterEngine.for_model("paperclip/claude_local/opus")
    assert_equal "codex_custom", Collavre::CliProxy::AdapterEngine.for_model("paperclip/codex_custom/groq/llama")
  end

  # nil means "fall back to the gateway rollup". A proxy that ships a new
  # adapter must not have its agents reported offline by a Collavre that has
  # never heard of the engine behind it.
  test "returns nil for anything it does not recognize" do
    assert_nil Collavre::CliProxy::AdapterEngine.for_model("paperclip/brand_new_local")
    assert_nil Collavre::CliProxy::AdapterEngine.for_model("gpt-4o")
    assert_nil Collavre::CliProxy::AdapterEngine.for_model(nil)
  end
end
