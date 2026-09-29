# frozen_string_literal: true

require "test_helper"

class AgentToolPermissionTest < ActiveSupport::TestCase
  setup do
    @agent = users(:ai_bot)
    @agent.update!(tools: %w[meta_tool cron_list])
    @policy = Collavre::AgentToolPermission
  end

  teardown { Collavre::Current.reset }

  test "only selected tools are allowed, while human access remains unchanged" do
    assert @policy.allowed?("cron_list", agent: @agent)
    refute @policy.allowed?("cron_cancel", agent: @agent)
    assert @policy.allowed?("cron_cancel", agent: users(:one))
    assert @policy.allowed?("cron_cancel", agent: nil)
    @agent.update!(tools: [])
    refute @policy.allowed?("cron_list", agent: @agent)
    @agent.update_column(:tools, nil)
    refute @policy.allowed?("cron_list", agent: @agent)
  end

  test "revocation ignores stale agent attributes and the SQL query cache" do
    Collavre::User.cache do
      assert @policy.allowed?("cron_list", agent: @agent)
      Collavre::User.find(@agent.id).update!(tools: [])
      assert_includes @agent.tools, "cron_list"
      refute @policy.allowed?("cron_list", agent: @agent)
    end
    @agent.destroy!
    refute @policy.allowed?("cron_list", agent: @agent)
  end

  test "workspace identity overrides human and agent token owners" do
    workspace = Struct.new(:agent).new(@agent)
    [ users(:one), Collavre::Kollavy.seed! ].each do |owner|
      Collavre::Current.set(user: owner, mcp_agent_workspace: workspace) do
        assert_equal @agent, @policy.current_agent
        refute @policy.allowed?("cron_cancel")
      end
    end
    Collavre::Current.set(user: @agent) { assert_equal @agent, @policy.current_agent }
    Collavre::Current.set(user: users(:one)) { assert_nil @policy.current_agent }
    task = Struct.new(:agent).new(@agent)
    Collavre::Current.set(user: users(:one), agent_turn: { task: task }) do
      assert_equal @agent, @policy.current_agent
    end
  end

  test "all executable meta wrappers need grants but discovery does not execute a target" do
    %w[run call].each do |action|
      args = { action: action, tool_name: "meta_tool", arguments: {
        "action" => action, "tool_name" => "cron_cancel", "arguments" => { "key" => "job" }
      } }
      assert_raises(Collavre::Tools::PermissionDeniedError) do
        @policy.authorize_call!("meta_tool", args, agent: @agent)
      end
      @policy.authorize_call!("meta_tool", { action: action, tool_name: "cron_list" }, agent: @agent)
    end
    @policy.authorize_call!("meta_tool", { action: "get", tool_name: "cron_cancel" }, agent: @agent)
    @policy.authorize_call!("meta_tool", nil, agent: @agent)
    @agent.update!(tools: [ "cron_list" ])
    assert_raises(Collavre::Tools::PermissionDeniedError) do
      @policy.authorize_call!("meta_tool", { action: "list" }, agent: @agent)
    end
  end

  test "meta dispatch refuses an unselected target before service execution" do
    Collavre::Current.set(user: @agent) do
      %w[run call].each do |action|
        result = ::Tools::MetaToolService.new.call(action: action, tool_name: "cron_cancel", arguments: { key: "missing" })
        assert_equal I18n.t("collavre.mcp_tools.agent_tool_denied", tool_name: "cron_cancel"), result[:error]
      end
      result = ::Tools::MetaToolService.new.call(action: "run", tool_name: "cron_list")
      assert result.dig(:result, :success), result.inspect
    end
  end

  test "RubyLLM execution boundary rejects revoked direct and nested calls before approval" do
    client = Collavre::AiClient.new(vendor: "openai", model: "test", system_prompt: nil, context: { user: @agent })
    client.define_singleton_method(:check_tool_approval!) { |_call| raise "Approval must not run" }
    boundary = nil
    chat = Object.new
    chat.define_singleton_method(:on_tool_call) { |&block| boundary = block }
    chat.define_singleton_method(:after_tool_result) { |&block| }
    client.send(:install_tool_boundary, chat)
    Collavre::User.find(@agent.id).update!(tools: [ "meta_tool" ])
    [ [ "cron_list", {} ], [ "meta_tool", { action: "run", tool_name: "cron_list" } ] ].each do |name, arguments|
      call = RubyLLM::ToolCall.new(id: "call-1", name: name, arguments: arguments)
      assert_raises(Collavre::Tools::PermissionDeniedError) { boundary.call(call) }
    end
  end
end
