require "test_helper"

class RubyLlmToolConversionTest < ActiveSupport::TestCase
  test "converts creative_create_service to RubyLLM tool without error" do
    tool_names = ["creative_create_service"]

    # This should not raise "undefined method 'float'" error
    assert_nothing_raised do
      tool_classes = ::Tools::MetaToolService.ruby_llm_tools(tool_names)
      assert tool_classes.present?, "Expected tool classes to be returned"
    end
  end

  test "converts creative_update_service to RubyLLM tool without error" do
    tool_names = ["creative_update_service"]

    assert_nothing_raised do
      tool_classes = ::Tools::MetaToolService.ruby_llm_tools(tool_names)
      assert tool_classes.present?, "Expected tool classes to be returned"
    end
  end

  test "converts all creative tools to RubyLLM tools" do
    tool_names = ["creative_create_service", "creative_update_service", "creative_retrieval_service"]

    assert_nothing_raised do
      tool_classes = ::Tools::MetaToolService.ruby_llm_tools(tool_names)
      assert_equal 3, tool_classes.length, "Expected 3 tool classes"
    end
  end

  test "float type is mapped to number in RubyLLM params DSL" do
    # Verify the monkey patch is working
    assert_equal :number, ToolSchema::RubyLlmBuilder.scalar_method(:float)
    assert_equal :integer, ToolSchema::RubyLlmBuilder.scalar_method(:integer)
    assert_equal :string, ToolSchema::RubyLlmBuilder.scalar_method(:string)
    assert_equal :boolean, ToolSchema::RubyLlmBuilder.scalar_method(:boolean)
  end
end
