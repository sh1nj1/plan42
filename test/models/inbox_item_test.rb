require "test_helper"

class InboxItemTest < ActiveSupport::TestCase
  test "default state is new" do
    item = InboxItem.new(message_key: "inbox.no_messages", owner: users(:one), message_params: {})
    assert item.save
    assert_equal "new", item.state
  end

  test "read item can be marked unread" do
    item = InboxItem.create!(message_key: "inbox.no_messages", owner: users(:one), state: "read", message_params: {})
    item.update!(state: "new")
    assert_equal "new", item.state
  end
end
