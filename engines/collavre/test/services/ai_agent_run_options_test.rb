# frozen_string_literal: true

require "test_helper"

class AiAgentRunOptionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @agent = users(:ai_bot)
    @agent.update!(routing_expression: "true")
    @agent.update_columns(llm_vendor: "cli_proxy", llm_model: "paperclip/claude_local/sonnet", reasoning_effort: "low")
  end

  def run_turn_for(comment)
    task = Collavre::Task.create!(
      name: "Run options task",
      status: "running",
      trigger_event_name: "comment_created",
      trigger_event_payload: {
        "comment" => { "id" => comment.id, "content" => comment.content },
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => comment.topic_id }
      },
      agent: @agent,
      topic_id: comment.topic_id
    )
    client = Object.new
    client.define_singleton_method(:chat) { |*_args, **_kwargs, &block| block.call("Answer") }
    client.define_singleton_method(:last_handoff_failed?) { false }
    client.define_singleton_method(:handed_off?) { true }
    captured = nil
    factory = lambda do |**options|
      captured = options
      client
    end

    Collavre::AiClient.stub(:new, factory) { Collavre::AiAgentService.new(task).call }
    [ captured, Collavre::Comment.where(task_id: task.id).where.not(id: comment.id).last ]
  end

  test "a human message's run options override the agent and are recorded on the reply" do
    comment = @creative.comments.create!(
      content: "Hello AI", user: @user,
      agent_run_options: { "model" => "paperclip/claude_local/opus", "reasoning_effort" => "max" }
    )

    options, reply = run_turn_for(comment)

    assert_equal "paperclip/claude_local/sonnet", options[:model]
    assert_equal "max", options[:context][:reasoning_effort]
    assert_equal({ "model" => "paperclip/claude_local/sonnet", "reasoning_effort" => "max" }, reply&.reload&.agent_run_options)
  end

  test "without message options the agent defaults are used" do
    comment = @creative.comments.create!(content: "Hello AI", user: @user)

    options, = run_turn_for(comment)

    assert_equal "paperclip/claude_local/sonnet", options[:model]
    assert_equal "low", options[:context][:reasoning_effort]
  end

  test "an agent-authored trigger does not pass its run options on" do
    upstream = Collavre::User.create!(
      name: "Upstream", email: "run-options-upstream@ai.local", password: SecureRandom.hex(24),
      llm_vendor: "openai", llm_model: "gpt-4o", created_by_id: @user.id
    )
    comment = @creative.comments.create!(
      content: "Relay", user: upstream,
      agent_run_options: { "model" => "paperclip/claude_local/opus", "reasoning_effort" => "max" }
    )

    options, = run_turn_for(comment)

    assert_equal "paperclip/claude_local/sonnet", options[:model]
    assert_equal "low", options[:context][:reasoning_effort]
  end

  test "other vendors take no run options" do
    @agent.update_columns(llm_vendor: "openai", llm_model: "gpt-4o")
    comment = @creative.comments.create!(content: "Hello AI", user: @user, agent_run_options: { "reasoning_effort" => "high" })

    options, = run_turn_for(comment)

    assert_equal "gpt-4o", options[:model]
    assert_nil options[:context][:reasoning_effort]
  end
end
