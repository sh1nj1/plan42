# frozen_string_literal: true

require "test_helper"

class McpToolRegistrarTest < ActiveSupport::TestCase
  EVAL_STARTED = Queue.new
  EVAL_GATE = Queue.new

  teardown do
    Tools::MetaToolWriteService.new.delete_tool("authored_probe")
    Tools.send(:remove_const, :AuthoredProbeService) if Tools.const_defined?(:AuthoredProbeService, false)
  end

  test "approval refuses a source whose class declares a different tool_name" do
    user = users(:one)
    source = tool_source.sub("    tool_description", "    tool_name \"shadow_probe\"\n    tool_description")
    host = Creative.new(user: user)
    host.content_type_input = "markdown"
    host.markdown_source = "# probe\n\n```ruby\n#{source}```\n"
    host.save!
    Collavre::McpService.new.update_from_creative(host)

    tool = McpTool.find_by!(name: "authored_probe")
    error = assert_raises(RuntimeError) { tool.approve! }
    assert_match(/declares tool_name "shadow_probe", expected "authored_probe"/, error.message)
    assert_not tool.reload.active?
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "the failed approval removes its class"
    assert_nil Tools::MetaToolService.new.find_schema("shadow_probe")
  end

  test "a source that fails after extending ToolMeta leaves nothing registered" do
    raising = tool_source.sub("    tool_description", "    raise \"boom\"\n    tool_description")
    helper = tool_source + <<~RUBY
      class Tools::AuthoredProbeHelper
        extend ToolMeta
      end
    RUBY

    { raising => /Failed to evaluate source: boom/, raising.sub('raise "boom"', "raise NotImplementedError, \"later\"") => /Failed to evaluate source: later/ }
      .each do |source, message|
        tool = approvable_tool(source)
        assert_no_changes -> { ToolMeta.registry.dup } do
          assert_raises(RuntimeError, match: message) { tool.approve! }
        end
        assert_not tool.reload.active?
        assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
        assert_not Tools.const_defined?(:AuthoredProbeService, false), "the partial class is not left behind"
        tool.creative.destroy!
      end

    approvable_tool(helper).approve!
    assert_includes ToolMeta.registry, Tools::AuthoredProbeService
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeHelper
  ensure
    Tools.send(:remove_const, :AuthoredProbeHelper) if Tools.const_defined?(:AuthoredProbeHelper, false)
  end

  test "a registration during another's evaluation survives that evaluation's rollback" do
    waiting = tool_source.sub("    tool_description", "    McpToolRegistrarTest::EVAL_STARTED << true\n    McpToolRegistrarTest::EVAL_GATE.pop\n    raise \"late\"\n    tool_description")
    other = tool_source.gsub("authored_probe", "authored_probe_b").gsub("AuthoredProbeService", "AuthoredProbeBService")

    failing = Thread.new { Collavre::McpService.register_tool_from_source(waiting, expected_name: "authored_probe") rescue $! }
    EVAL_STARTED.pop
    concurrent = Thread.new { Collavre::McpService.register_tool_from_source(other, expected_name: "authored_probe_b") }
    assert_nil concurrent.join(0.5), "registration must wait for the in-flight evaluation"
    EVAL_GATE << true

    assert_match(/Failed to evaluate source: late/, failing.value.message)
    concurrent.join
    assert_includes ToolMeta.registry, Tools::AuthoredProbeBService
    assert Tools::MetaToolService.new.find_schema("authored_probe_b")
  ensure
    EVAL_GATE << true if failing&.alive?
    [ failing, concurrent ].compact.each { |t| t.join(5) }
    EVAL_STARTED.clear
    EVAL_GATE.clear
    Tools::MetaToolWriteService.new.delete_tool("authored_probe_b")
    Tools.send(:remove_const, :AuthoredProbeBService) if Tools.const_defined?(:AuthoredProbeBService, false)
  end

  test "approval refuses a class another tool or the application already defines" do
    owner = approvable_tool(tool_source)
    owner.approve!
    other = approvable_tool(tool_source.sub('tool_name "authored_probe"', 'tool_name "other_probe"'), "other_probe")
    builtin = approvable_tool(tool_source.sub("AuthoredProbeService", "CreativeRetrievalService").sub('tool_name "authored_probe"', 'tool_name "builtin_probe"'), "builtin_probe")
    builtin_metadata = Tools::CreativeRetrievalService.tool_metadata.dup

    { other => "Tools::AuthoredProbeService", builtin => "Tools::CreativeRetrievalService" }.each do |tool, class_name|
      assert_raises(RuntimeError, match: /#{class_name} is already defined by another tool or the application/) { tool.approve! }
      assert_not tool.reload.active?
    end
    assert_equal builtin_metadata, Tools::CreativeRetrievalService.tool_metadata
    assert_equal "authored_probe", Tools::AuthoredProbeService.tool_metadata[:name]
    assert_nil Tools::MetaToolService.new.find_schema("other_probe")

    Tools::MetaToolWriteService.new.delete_tool("authored_probe")
    owner.approve!
    assert Tools::MetaToolService.new.find_schema("authored_probe"), "a tool may reopen the class it defined"
  end

  test "approval refuses a class whose generated tool constants another tool or the application uses" do
    approvable_tool(tool_source).approve!
    other = approvable_tool(tool_source.sub("module Tools", "module Mcp").sub('tool_name "authored_probe"', 'tool_name "other_probe"'), "other_probe")
    builtin = approvable_tool(tool_source.sub("AuthoredProbeService", "CreativeRetrievalServiceService").sub('tool_name "authored_probe"', 'tool_name "builtin_probe"'), "builtin_probe")
    builtin_class = Tools::CreativeRetrievalService

    { other => /Mcp::AuthoredProbeService builds Tools::AuthoredProbe, which another tool/,
      builtin => /Tools::CreativeRetrievalServiceService builds Tools::CreativeRetrievalService, which another tool/ }.each do |tool, message|
      assert_raises(RuntimeError, match: message) { tool.approve! }
      assert_not tool.reload.active?
    end
    assert_same builtin_class, Tools::CreativeRetrievalService
    assert_not Mcp.const_defined?(:AuthoredProbeService, false), "a refused source is never evaluated"
    assert_not Tools.const_defined?(:CreativeRetrievalServiceService, false)
    assert Tools::MetaToolService.new.find_schema("authored_probe")
    assert_nil Tools::MetaToolService.new.find_schema("other_probe")
  end

  test "deleting a tool or abandoning its failed approval frees the class for another tool" do
    approved = approvable_tool(tool_source)
    approved.approve!
    approved.creative.destroy!
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "deleting the tool removes the class it defined"

    failed = approvable_tool(tool_source.sub("    tool_description", "    raise \"boom\"\n    tool_description"))
    assert_raises(RuntimeError, match: /boom/) { failed.approve! }
    failed.creative.destroy!

    renamed = approvable_tool(tool_source.sub('tool_name "authored_probe"', 'tool_name "renamed_probe"'), "renamed_probe")
    renamed.approve!
    assert Tools::MetaToolService.new.find_schema("renamed_probe")
  ensure
    Tools::MetaToolWriteService.new.delete_tool("renamed_probe")
  end

  test "re-approval requires the source to redeclare the class it registers" do
    approved = approvable_tool(tool_source)
    approved.approve!
    stale = "class Tools::AuthoredProbeService\nend\n\n" + tool_source.sub("AuthoredProbeService", "AuthoredProbeNextService")
    host = approved.creative
    host.content_type_input = "markdown"
    host.markdown_source = "# probe\n\n```ruby\n#{stale}```\n"
    host.save!
    Collavre::McpService.new.update_from_creative(host)
    tool = McpTool.find_by!(name: "authored_probe")
    assert_not tool.active?, "editing the source resets approval"

    assert_raises(RuntimeError, match: /Tools::AuthoredProbeService does not extend ToolMeta in the source/) { tool.approve! }
    assert_not tool.reload.active?
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "the failed approval removes the class it would register"
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeNextService
    assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
  ensure
    Tools.send(:remove_const, :AuthoredProbeNextService) if Tools.const_defined?(:AuthoredProbeNextService, false)
  end

  test "a verified class leaves the registry when building its tool classes fails" do
    unsigned = approvable_tool(tool_source.sub(/^    sig \{.*\n/, ""))
    assert_raises(RuntimeError, match: /Failed to register tool/) { unsigned.approve! }
    assert_not unsigned.reload.active?
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "the failed approval removes its class"

    tool = unsigned
    tool.update!(source_code: tool_source)
    ToolSchema::FastMcpFactory.stub(:build, ->(*) { raise ArgumentError, "bad schema" }) do
      assert_raises(RuntimeError, match: /Failed to register Tools::AuthoredProbeService: bad schema/) { tool.approve! }
    end
    assert_not tool.reload.active?
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "the failed approval removes its class"
    assert_not Tools.const_defined?(:AuthoredProbe, false), "the RubyLLM tool built before the failure is removed"
    assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
  end

  test "a class the source freezes leaves the registry when its owner cannot be recorded" do
    tool = approvable_tool(tool_source + "Tools::AuthoredProbeService.freeze\n")
    assert_no_changes -> { ToolMeta.registry.dup } do
      assert_raises(RuntimeError, match: /Failed to record the owner of Tools::AuthoredProbeService/) { tool.approve! }
    end
    assert_not tool.reload.active?
    assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "the frozen class this approval defined is removed"

    tool.creative.destroy!
    approvable_tool(tool_source).approve!
    assert Tools::MetaToolService.new.find_schema("authored_probe"), "a corrected source approves without a restart"
  end

  test "a tool can re-approve its class after the service is reloaded" do
    tool = approvable_tool(tool_source)
    tool.approve!
    Tools::MetaToolWriteService.new.delete_tool("authored_probe")
    reload_mcp_service

    tool.approve!
    assert Tools::MetaToolService.new.find_schema("authored_probe")
  end

  test "approval refuses constants that another worker's approved tool uses" do
    earlier = approvable_tool(tool_source)
    earlier.update!(approved_at: 1.minute.ago) # approved on another worker: never evaluated here
    later = approvable_tool(tool_source.sub('tool_name "authored_probe"', 'tool_name "other_probe"'), "other_probe")
    renamed = approvable_tool(tool_source.sub("AuthoredProbeService", "AuthoredProbeServiceService").sub('tool_name "authored_probe"', 'tool_name "renamed_probe"'), "renamed_probe")

    { later => /Tools::AuthoredProbeService uses Tools::AuthoredProbeService, which another approved tool/,
      renamed => /Tools::AuthoredProbeServiceService uses Tools::AuthoredProbeService, which another approved tool/ }.each do |tool, message|
      assert_raises(RuntimeError, match: message) { tool.approve! }
      assert_not tool.reload.active?
    end
    assert_not Tools.const_defined?(:AuthoredProbeService, false), "a refused source is never evaluated"

    later.update!(approved_at: Time.current) # both approved on different workers
    McpService.load_active_tools
    assert_equal "authored_probe", Tools::AuthoredProbeService.tool_metadata[:name], "the earlier approval wins after a restart"
    assert_nil Tools::MetaToolService.new.find_schema("other_probe")
  end

  test "a failed reload removes the tool's generated constants so the next load registers it" do
    once = "    raise \"loaded twice\" if defined?(LOADED)\n    LOADED = true\n\n    def call"
    tool = approvable_tool(tool_source.sub("    def call", once))
    tool.approve!
    assert Tools.const_defined?(:AuthoredProbe, false)

    McpService.load_active_tools
    assert_not Tools.const_defined?(:AuthoredProbeService, false)
    assert_not Tools.const_defined?(:AuthoredProbe, false), "the RubyLLM tool leaves with its service class"
    assert_not Mcp.const_defined?(:AuthoredProbe, false), "the FastMcp tool leaves with its service class"
    assert_nil Tools::MetaToolService.new.find_schema("authored_probe")

    McpService.load_active_tools
    assert Tools::MetaToolService.new.find_schema("authored_probe"), "the next load registers the approved tool again"
  end

  private

  # What a development reload does: a fresh McpService (and its ::McpService
  # alias), while the dynamically evaluated tool classes stay defined.
  def reload_mcp_service
    path = Collavre::McpService.method(:register_tool_from_source).source_location.first
    Collavre.send(:remove_const, :McpService)
    load path
    Object.send(:remove_const, :McpService)
    Object.const_set(:McpService, Collavre::McpService)
  end

  def approvable_tool(source, name = "authored_probe")
    host = Creative.new(user: users(:one))
    host.content_type_input = "markdown"
    host.markdown_source = "# probe\n\n```ruby\n#{source}```\n"
    host.save!
    Collavre::McpService.new.update_from_creative(host)
    McpTool.find_by!(name: name)
  end

  def tool_source
    <<~RUBY
      module Tools
        class AuthoredProbeService
          extend T::Sig
          extend ToolMeta

          tool_name "authored_probe"
          tool_description "Probe"
          tool_param :creative_id, description: "Creative to operate on", required: true

          sig { params(creative_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
          def call(creative_id:)
            { success: true, id: creative_id }
          end
        end
      end
    RUBY
  end
end
