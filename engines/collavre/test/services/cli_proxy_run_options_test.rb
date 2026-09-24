# frozen_string_literal: true

require "test_helper"

class CliProxyRunOptionsTest < ActiveSupport::TestCase
  RunOptions = Collavre::CliProxy::RunOptions

  def agent(model: "paperclip/claude_local/sonnet", effort: nil)
    Collavre::User.new(llm_vendor: "cli_proxy", llm_model: model, reasoning_effort: effort)
  end

  test "agent defaults apply without message options" do
    options = RunOptions.resolve(agent: agent(effort: "high"))

    assert_equal "paperclip/claude_local/sonnet", options.model
    assert_equal "high", options.reasoning_effort
    assert_equal({ "model" => "paperclip/claude_local/sonnet", "reasoning_effort" => "high" }, options.to_h)
  end

  test "no effort anywhere leaves the proxy default" do
    options = RunOptions.resolve(agent: agent)

    assert_nil options.reasoning_effort
    assert_equal({ "model" => "paperclip/claude_local/sonnet" }, options.to_h)
  end

  test "messages override effort but cannot override the model" do
    options = RunOptions.resolve(
      agent: agent(effort: "low"),
      message_options: { "model" => " paperclip/claude_local/opus ", "reasoning_effort" => "max" }
    )

    assert_equal "paperclip/claude_local/sonnet", options.model
    assert_equal "max", options.reasoning_effort
  end

  test "a message cannot switch the adapter" do
    options = RunOptions.resolve(agent: agent, message_options: { model: "paperclip/codex_local/gpt-5.5" })
    assert_equal "paperclip/claude_local/sonnet", options.model

    options = RunOptions.resolve(agent: agent, message_options: { model: "gpt-4o" })
    assert_equal "paperclip/claude_local/sonnet", options.model

    outside = RunOptions.resolve(agent: agent(model: "gpt-4o"), message_options: { model: "gpt-4o-mini" })
    assert_equal "gpt-4o", outside.model
  end

  test "efforts the engine does not accept fall back to the next candidate" do
    claude = RunOptions.resolve(agent: agent(effort: "high"), message_options: { reasoning_effort: "minimal" })
    assert_equal "high", claude.reasoning_effort

    codex = RunOptions.resolve(agent: agent(model: "paperclip/codex_local", effort: "max"),
                               message_options: { reasoning_effort: "bogus" })
    assert_nil codex.reasoning_effort

    custom = RunOptions.resolve(agent: agent(model: "paperclip/codex_custom/openai/gpt-5"),
                                message_options: { reasoning_effort: "none" })
    assert_equal "none", custom.reasoning_effort
  end

  test "sanitize keeps known non-blank keys only" do
    assert_nil RunOptions.sanitize_message_options(nil)
    assert_nil RunOptions.sanitize_message_options("high")
    assert_nil RunOptions.sanitize_message_options({ "model" => " ", "reasoning_effort" => "" })
    assert_nil RunOptions.sanitize_message_options({ "model" => "x" * 256 })
    assert_equal({ "reasoning_effort" => "high" },
                 RunOptions.sanitize_message_options({ reasoning_effort: " high ", other: "drop" }))
    params = ActionController::Parameters.new(model: "paperclip/claude_local/opus")
    assert_nil RunOptions.sanitize_message_options(params)
  end

  test "adapter and fast mode support follow the model id" do
    assert_equal "codex_local", RunOptions.adapter_for("paperclip/codex_local/gpt-5.5")
    assert_nil RunOptions.adapter_for("gpt-4o")
    assert_nil RunOptions.adapter_for("paperclip/")
    assert RunOptions.fast_mode_supported?("paperclip/codex_local")
    assert_not RunOptions.fast_mode_supported?("paperclip/codex_custom/openai/gpt-5")
    assert_equal [], RunOptions.efforts_for("gpt-4o")
  end
end
