# frozen_string_literal: true

require "test_helper"

class InboxItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @item = InboxItem.create!(message_key: "inbox.no_messages", owner: @user, message_params: {})
    sign_in_as(@user, password: "password")
  end

  test "update to a valid state marks it read" do
    patch inbox_item_url(@item), params: { state: "read" }, as: :json
    assert_response :no_content
    assert @item.reload.read?
  end

  test "update with an invalid state returns 422 not 500" do
    patch inbox_item_url(@item), params: { state: "bogus" }, as: :json
    assert_response :unprocessable_entity
    assert @item.reload.new?
  end
end
