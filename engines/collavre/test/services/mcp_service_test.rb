require "test_helper"

class McpServiceTest < ActiveSupport::TestCase
  test "register_tool_from_source delegates to engine service" do
    source_code = <<~RUBY
      class Tools::TestTool
        extend T::Sig
        extend ToolMeta
        tool_name "test_tool"
        tool_description "Test Tool"
      end
    RUBY

    mock_service = Minitest::Mock.new
    mock_service.expect :register_tool_from_source, { status: "registered" }, [], source: source_code, before_call: Proc, after_call: Proc

    Tools::MetaToolWriteService.stub :new, mock_service do
      McpService.register_tool_from_source(source_code)
    end

    mock_service.verify
  end

  test "delete_tool delegates to engine service" do
    tool_name = "test_tool"

    mock_service = Minitest::Mock.new
    mock_service.expect :delete_tool, { success: "Tool deleted successfully" }, [ tool_name ]

    Tools::MetaToolWriteService.stub :new, mock_service do
      McpService.delete_tool(tool_name)
    end

    mock_service.verify
  end

  test "update_from_creative parses lexical code blocks" do
    user = users(:one)
    creative = Creative.create!(user: user, description: <<~HTML)
      <p>Here is a tool:</p>
      <pre class="lexical-code-block">
        class Tools::LexicalTool
          extend ToolMeta
          tool_name "lexical_tool"
          tool_description "Lexical Tool"
        end
      </pre>
    HTML

    # Mock the registration call to avoid actual engine interaction
    McpService.stub :register_tool_from_source, nil do
      McpService.new.update_from_creative(creative)
    end

    tool = McpTool.find_by(name: "lexical_tool")
    assert tool, "Tool should be created"
    assert_equal "Lexical Tool", tool.description
    assert_includes tool.source_code, "class Tools::LexicalTool"
  end

  test "update_from_creative handles br tags in code blocks" do
    user = users(:one)
    creative = Creative.create!(user: user, description: <<~HTML)
      <pre class="lexical-code-block">
        class Tools::BrTool<br>
          extend ToolMeta<br>
          tool_name "br_tool"<br>
        end
      </pre>
    HTML

    McpService.stub :register_tool_from_source, nil do
      McpService.new.update_from_creative(creative)
    end

    tool = McpTool.find_by(name: "br_tool")
    assert tool
    assert_includes tool.source_code, "class Tools::BrTool\n"
  end

  test "update_from_creative unregisters tool when source changes" do
    user = users(:one)
    creative = Creative.create!(user: user, description: <<~HTML)
      <pre class="lexical-code-block">
        class Tools::StaleTool
          extend ToolMeta
          tool_name "stale_tool"
        end
      </pre>
    HTML

    # 1. Initial creation
    McpService.stub :register_tool_from_source, nil do
      McpService.new.update_from_creative(creative)
    end

    tool = McpTool.find_by(name: "stale_tool")
    tool.update!(approved_at: Time.current) # Simulate approval

    # Expect delete_tool to be called
    mock_service = Minitest::Mock.new
    mock_service.expect :delete_tool, { success: "Deleted" }, [ "stale_tool" ]

    Tools::MetaToolWriteService.stub :new, mock_service do
      creative.update!(description: <<~HTML)
        <pre class="lexical-code-block">
          class Tools::StaleTool
            extend ToolMeta
            tool_name "stale_tool"
            # Changed source
          end
        </pre>
      HTML
    end

    mock_service.verify

    tool.reload
    assert_nil tool.approved_at
  end

  test "register_tool_from_source raises error on failure" do
    source_code = "invalid source"

    mock_service = Minitest::Mock.new
    mock_service.expect :register_tool_from_source, { error: "Syntax error" }, [], source: source_code, before_call: Proc, after_call: Proc

    Tools::MetaToolWriteService.stub :new, mock_service do
      assert_raises(RuntimeError) do
        McpService.register_tool_from_source(source_code)
      end
    end

    mock_service.verify
  end

  test "update_from_creative creates tool on effective_origin for linked creatives" do
    user = users(:one)
    origin = Creative.create!(user: user, description: "Origin")
    linked = Creative.create!(user: user, origin: origin, description: "Linked")

    # Mock registration to avoid engine calls
    McpService.stub :register_tool_from_source, nil do
      # We need to call update_from_creative manually or via update!
      # Since update! triggers the callback, let's use that.
      origin.update!(description: <<~HTML)
        <pre class="lexical-code-block">
          class Tools::LinkedTool
            extend ToolMeta
            tool_name "linked_tool"
          end
        </pre>
      HTML
    end

    # Tool should be on origin
    tool = McpTool.find_by(name: "linked_tool")
    assert tool
    assert_equal origin.id, tool.creative.id
    assert_not_equal linked, tool.creative
  end

  test "update_from_creative deletes tools removed from description" do
    user = users(:one)
    creative = Creative.create!(user: user, description: <<~HTML)
      <pre class="lexical-code-block">
        class Tools::RemovedTool
          extend ToolMeta
          tool_name "removed_tool"
        end
      </pre>
    HTML

    # Initial creation
    McpService.stub :register_tool_from_source, nil do
      McpService.new.update_from_creative(creative)
    end

    assert McpTool.exists?(name: "removed_tool")

    # Update description removing the tool
    # Expect delete_tool to be called via destroy callback
    mock_service = Minitest::Mock.new
    mock_service.expect :delete_tool, { success: "Deleted" }, [ "removed_tool" ]

    Tools::MetaToolWriteService.stub :new, mock_service do
      creative.update!(description: "<p>No tools here</p>")
    end

    mock_service.verify
    assert_not McpTool.exists?(name: "removed_tool")
  end

  test "filter_tools returns system tools for any user" do
    user = users(:one)
    system_tools = [
      { name: "system_tool_1", description: "System Tool 1" },
      { name: "system_tool_2", description: "System Tool 2" }
    ]

    # No McpTool records exist for these tools, so they are system tools
    result = McpService.filter_tools(system_tools, user)

    assert_equal 2, result.length
    assert_equal "system_tool_1", result[0][:name]
    assert_equal "system_tool_2", result[1][:name]
  end

  test "filter_tools returns system tools even without a user" do
    system_tools = [
      { name: "system_tool_1", description: "System Tool 1" }
    ]

    result = McpService.filter_tools(system_tools, nil)

    assert_equal 1, result.length
    assert_equal "system_tool_1", result[0][:name]
  end

  test "filter_tools returns dynamic tools when user has write permission" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Tool creative")
    McpTool.create!(creative: creative, name: "dynamic_tool", source_code: "class Foo; end")

    tools = [
      { name: "dynamic_tool", description: "Dynamic Tool" }
    ]

    result = McpService.filter_tools(tools, user)

    assert_equal 1, result.length
    assert_equal "dynamic_tool", result[0][:name]
  end

  test "filter_tools excludes dynamic tools when user has no permission" do
    owner = users(:one)
    other_user = users(:two)
    creative = Creative.create!(user: owner, description: "Tool creative")
    McpTool.create!(creative: creative, name: "private_tool", source_code: "class Foo; end")

    tools = [
      { name: "private_tool", description: "Private Tool" }
    ]

    result = McpService.filter_tools(tools, other_user)

    assert_empty result
  end

  test "filter_tools returns dynamic tools when user has shared write permission" do
    owner = users(:one)
    shared_user = users(:two)
    creative = Creative.create!(user: owner, description: "Shared tool creative")
    McpTool.create!(creative: creative, name: "shared_tool", source_code: "class Foo; end")

    # Grant write permission to shared_user and run jobs to propagate cache
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: shared_user, permission: :write)
    end

    tools = [
      { name: "shared_tool", description: "Shared Tool" }
    ]

    result = McpService.filter_tools(tools, shared_user)

    assert_equal 1, result.length
    assert_equal "shared_tool", result[0][:name]
  end

  test "filter_tools excludes dynamic tools when user only has read permission" do
    owner = users(:one)
    reader = users(:two)
    creative = Creative.create!(user: owner, description: "Read-only creative")
    McpTool.create!(creative: creative, name: "readonly_tool", source_code: "class Foo; end")

    # Grant only read permission and run jobs to propagate cache
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: reader, permission: :read)
    end

    tools = [
      { name: "readonly_tool", description: "Read-only Tool" }
    ]

    result = McpService.filter_tools(tools, reader)

    assert_empty result
  end

  test "filter_tools handles mixed system and dynamic tools" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Tool creative")
    McpTool.create!(creative: creative, name: "user_tool", source_code: "class Foo; end")

    tools = [
      { name: "system_tool", description: "System Tool" },
      { name: "user_tool", description: "User Tool" }
    ]

    result = McpService.filter_tools(tools, user)

    assert_equal 2, result.length
    tool_names = result.map { |t| t[:name] }
    assert_includes tool_names, "system_tool"
    assert_includes tool_names, "user_tool"
  end

  test "filter_tools returns empty array for blank tools" do
    user = users(:one)

    assert_equal [], McpService.filter_tools([], user)
    assert_equal [], McpService.filter_tools(nil, user)
  end
end
