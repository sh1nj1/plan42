# frozen_string_literal: true

require "test_helper"

class McpToolRestrictionTest < ActiveSupport::TestCase
  setup do
    @kollavy = Collavre::User.create!(email: Collavre::Kollavy::EMAIL, name: "Kollavy", password: "password-123",
                                      llm_vendor: "google", llm_model: "gemini-2.5-flash")
    @user = users(:one)
  end

  test "user_permitted? honours allowed_user_emails and ignores unrestricted tools" do
    assert Collavre::McpToolRegistry.user_permitted?("collavre_source_read", @kollavy)
    refute Collavre::McpToolRegistry.user_permitted?("collavre_source_read", @user)
    refute Collavre::McpToolRegistry.user_permitted?("collavre_source_read", nil)
    assert Collavre::McpToolRegistry.user_permitted?("creative_retrieval_service", @user)
    assert Collavre::McpToolRegistry.user_permitted?("not_a_registered_tool", nil)
  end

  test "filter_tools hides restricted system tools from other users" do
    tools = [ { name: "collavre_source_read" }, { name: "creative_retrieval_service" } ]

    assert_equal [ "creative_retrieval_service" ], Collavre::McpService.filter_tools(tools, @user).map { |t| t[:name] }
    assert_equal 2, Collavre::McpService.filter_tools(tools, @kollavy).size
  end

  test "available_tools only offers source tools to Kollavy" do
    refute_includes Collavre::McpService.available_tools(@user).map { |t| t[:name] }, "collavre_source_list"
    assert_includes Collavre::McpService.available_tools(@kollavy).map { |t| t[:name] }, "collavre_source_list"
  end

  test "meta tool access refuses restricted tools to other users" do
    Collavre::Current.set(user: @user) { refute Collavre::McpToolAccess.allowed?("collavre_source_read") }
    Collavre::Current.set(user: @kollavy) { assert Collavre::McpToolAccess.allowed?("collavre_source_read") }
    Collavre::Current.set(user: @user) { assert Collavre::McpToolAccess.allowed?("creative_retrieval_service") }
  end
end
