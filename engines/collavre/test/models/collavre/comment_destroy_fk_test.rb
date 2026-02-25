# frozen_string_literal: true

require_relative "../../test_helper"

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

    test "destroying comment nullifies quoted_comment_id on quoting comments" do
      original = Collavre::Comment.create!(creative: @creative, content: "original", user: @user)
      quoting = Collavre::Comment.create!(creative: @creative, content: "reply", user: @user, quoted_comment_id: original.id)

      original.destroy!

      quoting.reload
      assert_nil quoting.quoted_comment_id
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
