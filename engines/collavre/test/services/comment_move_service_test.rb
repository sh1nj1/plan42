require "test_helper"

module Collavre
  class CommentMoveServiceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      Current.user = @user
    end

    teardown do
      Current.user = nil
    end

    test "raises error when no comment_ids provided" do
      service = CommentMoveService.new(creative: @creative, user: @user)
      error = assert_raises(CommentMoveService::MoveError) do
        service.call(comment_ids: [])
      end
      assert_equal I18n.t("collavre.comments.move_no_selection"), error.message
    end

    test "raises error when target is invalid" do
      service = CommentMoveService.new(creative: @creative, user: @user)
      error = assert_raises(CommentMoveService::MoveError) do
        service.call(comment_ids: [ 1 ])
      end
      assert_equal I18n.t("collavre.comments.move_invalid_target"), error.message
    end

    test "raises error when target creative does not exist" do
      service = CommentMoveService.new(creative: @creative, user: @user)
      error = assert_raises(CommentMoveService::MoveError) do
        service.call(comment_ids: [ 1 ], target_creative_id: -999)
      end
      assert_equal I18n.t("collavre.comments.move_invalid_target"), error.message
    end
  end
end
