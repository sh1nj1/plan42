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
    post request_permission_creative_path(@creative)

    assert_response :ok

    item = InboxItem.order(:created_at).last
    assert_equal @owner, item.owner
    assert_equal "inbox.permission_requested", item.message_key
    message = item.localized_message
    assert_includes message, "Requester"
    expected_short = ActionController::Base.helpers.strip_tags(@creative.description).truncate(10)
    assert_includes message, expected_short
    assert_includes item.link, "share_request=#{CGI.escape(@requester.email)}"
  end
end
