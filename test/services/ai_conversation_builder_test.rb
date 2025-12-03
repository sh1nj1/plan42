require "test_helper"

class AiConversationBuilderTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @ai_user = users(:ai_bot)
    @creative = creatives(:tshirt)
    @builder = AiConversationBuilder.new(creative: @creative, ai_user: @ai_user)
  end

  test "builds messages with creative context" do
    messages = @builder.build_messages(payload: "Hello")

    assert_equal 2, messages.length
    assert_equal "user", messages.first[:role]
    assert_match /Creative:/, messages.first[:parts].first[:text]
    assert_equal "user", messages.last[:role]
    assert_equal "Hello", messages.last[:parts].first[:text]
  end

  test "includes conversation history" do
    # Create some comments
    @creative.comments.create!(content: "User comment", user: @user)
    @creative.comments.create!(content: "AI response", user: @ai_user)

    messages = @builder.build_messages(include_history: true)

    # 1 (context) + 2 (history) = 3
    assert_equal 3, messages.length

    assert_equal "user", messages[1][:role]
    assert_equal "User comment", messages[1][:parts].first[:text]

    assert_equal "model", messages[2][:role]
    assert_equal "AI response", messages[2][:parts].first[:text]
  end

  test "cleans mentions from user comments" do
    @creative.comments.create!(content: "@#{@ai_user.name}: Help me", user: @user)

    messages = @builder.build_messages(include_history: true)

    assert_equal "user", messages[1][:role]
    assert_equal "Help me", messages[1][:parts].first[:text]
  end

  test "filters private comments" do
    @creative.comments.create!(content: "Private comment", user: @user, private: true)

    messages = @builder.build_messages(include_history: true)

    # Should only contain context
    assert_equal 1, messages.length
  end

  test "includes private comments for the owner" do
    @creative.comments.create!(content: "Private comment", user: @user, private: true)

    messages = @builder.build_messages(include_history: true, user_for_history: @user)

    assert_equal 2, messages.length
    assert_equal "Private comment", messages[1][:parts].first[:text]
  end
end
