# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentDestroyFkTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = Collavre::Creative.create!(description: "test", progress: 0.0, user: @user)
      Collavre::Current.user = @user
    end

    test "destroying comment nullifies inbox_items comment_id" do
      comment = Collavre::Comment.create!(creative: @creative, content: "test", user: @user)
      inbox_item = Collavre::InboxItem.create!(
        owner: @user, creative: @creative, comment: comment,
        message_key: "inbox.test", link: "/test"
      )

      comment.destroy!

      inbox_item.reload
      assert_nil inbox_item.comment_id
    end

    test "destroying comment also destroys quoting comments" do
      original = Collavre::Comment.create!(creative: @creative, content: "original", user: @user)
      quoting = Collavre::Comment.create!(creative: @creative, content: "reply", user: @user, quoted_comment_id: original.id)

      original.destroy!

      assert_not Collavre::Comment.exists?(quoting.id), "Quoting comment should be destroyed when quoted comment is deleted"
    end

    test "destroying comment cascades through nested quoting comments" do
      original = Collavre::Comment.create!(creative: @creative, content: "original", user: @user)
      quoting1 = Collavre::Comment.create!(creative: @creative, content: "reply1", user: @user, quoted_comment_id: original.id)
      quoting2 = Collavre::Comment.create!(creative: @creative, content: "reply2", user: @user, quoted_comment_id: quoting1.id)

      original.destroy!

      assert_not Collavre::Comment.exists?(quoting1.id), "First-level quoting comment should be destroyed"
      assert_not Collavre::Comment.exists?(quoting2.id), "Second-level quoting comment should also be destroyed"
    end

    test "destroying a comment that quotes another does not affect the quoted comment" do
      original = Collavre::Comment.create!(creative: @creative, content: "original", user: @user)
      quoting = Collavre::Comment.create!(creative: @creative, content: "reply", user: @user, quoted_comment_id: original.id)

      quoting.destroy!

      assert Collavre::Comment.exists?(original.id), "Original quoted comment should not be affected"
    end

    test "destroying review comment nullifies review_comment_id on comment_versions" do
      original = Collavre::Comment.create!(creative: @creative, content: "original", user: @user)
      review_comment = Collavre::Comment.create!(
        creative: @creative, content: "review feedback", user: @user,
        quoted_comment_id: original.id
      )
      version = Collavre::CommentVersion.create!(
        comment: original, content: "revised content", version_number: 1,
        review_comment: review_comment
      )

      assert_nothing_raised { review_comment.destroy! }

      version.reload
      assert_nil version.review_comment_id, "review_comment_id should be nullified when review comment is deleted"
      assert Collavre::CommentVersion.exists?(version.id), "Version itself should not be deleted"
    end

    test "destroying comment with selected_version succeeds" do
      comment = Collavre::Comment.create!(creative: @creative, content: "test", user: @user)
      version = Collavre::CommentVersion.create!(
        comment: comment, content: "v1", version_number: 1
      )
      comment.update_column(:selected_version_id, version.id)

      assert_nothing_raised { comment.destroy! }
      assert_not Collavre::CommentVersion.exists?(version.id)
    end
  end
end
