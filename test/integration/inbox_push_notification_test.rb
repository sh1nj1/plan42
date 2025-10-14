require "test_helper"

class InboxPushNotificationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @inbox_item = inbox_items(:one_new)
  end

  test "marks inbox item as read when visiting link with inbox_item_id" do
    sign_in_as(@user, password: "password")
    assert_equal "new", @inbox_item.state

    assert_changes -> { @inbox_item.reload.state }, from: "new", to: "read" do
      get root_path, params: { inbox_item_id: @inbox_item.id }
      assert_response :success
    end
  end

  test "does not mark inbox item for different user" do
    sign_in_as(users(:two), password: "password")

    assert_no_changes -> { @inbox_item.reload.state } do
      get root_path, params: { inbox_item_id: @inbox_item.id }
      assert_response :success
    end
  end
end
