require "test_helper"

class CommentReactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @comment = Comment.create!(user: @user, creative: @creative, content: "Test comment")
  end

  test "should be valid" do
    reaction = CommentReaction.new(comment: @comment, user: @user, emoji: "👍")
    assert reaction.valid?
  end

  test "emoji filtering has a covering index for matching comment ids" do
    assert CommentReaction.connection.index_exists?(:comment_reactions, [ :emoji, :comment_id ])
  end

  test "should require emoji" do
    reaction = CommentReaction.new(comment: @comment, user: @user, emoji: nil)
    assert_not reaction.valid?
  end

  test "should require user" do
    reaction = CommentReaction.new(comment: @comment, user: nil, emoji: "👍")
    assert_not reaction.valid?
  end

  test "should require comment" do
    reaction = CommentReaction.new(comment: nil, user: @user, emoji: "👍")
    assert_not reaction.valid?
  end

  test "should enforce uniqueness of user per emoji per comment" do
    CommentReaction.create!(comment: @comment, user: @user, emoji: "👍")

    duplicate_reaction = CommentReaction.new(comment: @comment, user: @user, emoji: "👍")
    assert_not duplicate_reaction.valid?

    # User can react with different emoji
    different_emoji = CommentReaction.new(comment: @comment, user: @user, emoji: "❤️")
    assert different_emoji.valid?
  end
end
