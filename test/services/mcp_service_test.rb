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
    mock_service.expect :register_tool_from_source, { status: "registered" }, [], source: source_code

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
end
