require "test_helper"

class InboxItemTest < ActiveSupport::TestCase
  test "default state is new" do
    item = InboxItem.new(message: "Hi", owner: users(:one))
    assert item.save
    assert_equal "new", item.state
  end
end
