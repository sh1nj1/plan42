require "test_helper"
require "cgi"

class PermissionRequestTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner@example.com", password: TEST_PASSWORD, name: "Owner")
    @requester = User.create!(email: "req@example.com", password: TEST_PASSWORD, name: "Requester")
    @creative = Creative.create!(user: @owner, description: "Secret Creative Plan")
    sign_in_as(@requester)
  end

  test "creating permission request notifies owner" do
    inbox = Creative.inbox_for(@owner)
    inbox_before = inbox.comments.count

    post request_permission_creative_path(@creative)

    assert_response :ok

    assert_equal inbox_before + 1, inbox.comments.reload.count
    inbox_comment = inbox.comments.order(:id).last
    assert_nil inbox_comment.user
    assert_includes inbox_comment.content, "Requester"
    expected_short = ActionController::Base.helpers.strip_tags(@creative.description).truncate(10)
    assert_includes inbox_comment.content, expected_short
  end
end
