require "test_helper"

class InboxItemTest < ActiveSupport::TestCase
  test "default state is new" do
    item = InboxItem.new(message: "Hi", owner: users(:one))
    assert item.save
    assert_equal "new", item.state
  end

  test "read item can be marked unread" do
    item = InboxItem.create!(message: "Hi", owner: users(:one), state: "read")
    item.update!(state: "new")
    assert_equal "new", item.state
  end
end
