require "test_helper"

class CreativesControllerRequestPermissionTest < ActionDispatch::IntegrationTest
  test "owner requesting their own creative is rejected without sending anything" do
    creative = creatives(:childless_creative)
    sign_in_as(users(:one), password: "password")

    assert_no_difference -> { Comment.count } do
      post request_permission_creative_path(creative)
    end

    assert_response :unprocessable_entity
  end

  test "requester who already has write permission is rejected without sending anything" do
    creative = creatives(:childless_creative)
    perform_enqueued_jobs do
      Collavre::CreativeShare.create!(creative: creative, user: users(:two), permission: :write)
    end
    sign_in_as(users(:two), password: "password")

    assert_no_difference -> { Comment.count } do
      post request_permission_creative_path(creative)
    end

    assert_response :unprocessable_entity
  end

  test "requester with read-only permission can request write access" do
    creative = creatives(:childless_creative)
    perform_enqueued_jobs do
      Collavre::CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end
    sign_in_as(users(:two), password: "password")

    assert_difference -> { Comment.count }, 1 do
      post request_permission_creative_path(creative)
    end

    assert_response :success

    comment = Comment.order(:created_at).last
    expected_short_title = ApplicationController.helpers.strip_tags(creative.effective_origin.description).truncate(10)
    expected_link = "[#{expected_short_title}](#{Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)})"
    expected_message = I18n.t(
      "inbox.write_permission_requested",
      user: users(:two).display_name,
      short_title: expected_link,
      locale: users(:one).locale || "en"
    )
    assert_equal expected_message, comment.content
    assert_equal Creative.inbox_for(users(:one)), comment.creative
  end

  test "requester with feedback permission (below write) can request write access" do
    creative = creatives(:childless_creative)
    perform_enqueued_jobs do
      Collavre::CreativeShare.create!(creative: creative, user: users(:two), permission: :feedback)
    end
    sign_in_as(users(:two), password: "password")

    assert_difference -> { Comment.count }, 1 do
      post request_permission_creative_path(creative)
    end

    assert_response :success

    comment = Comment.order(:created_at).last
    expected_short_title = ApplicationController.helpers.strip_tags(creative.effective_origin.description).truncate(10)
    expected_link = "[#{expected_short_title}](#{Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)})"
    expected_message = I18n.t(
      "inbox.write_permission_requested",
      user: users(:two).display_name,
      short_title: expected_link,
      locale: users(:one).locale || "en"
    )
    assert_equal expected_message, comment.content
  end

  test "requester with zero access can still request permission (existing behavior preserved)" do
    creative = creatives(:childless_creative)
    sign_in_as(users(:two), password: "password")

    assert_difference -> { Comment.count }, 1 do
      post request_permission_creative_path(creative)
    end

    assert_response :success

    comment = Comment.order(:created_at).last
    expected_short_title = ApplicationController.helpers.strip_tags(creative.effective_origin.description).truncate(10)
    expected_link = "[#{expected_short_title}](#{Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)})"
    expected_message = I18n.t(
      "inbox.permission_requested",
      user: users(:two).display_name,
      short_title: expected_link,
      locale: users(:one).locale || "en"
    )
    assert_equal expected_message, comment.content
  end
end
