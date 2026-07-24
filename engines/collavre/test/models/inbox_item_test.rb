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

  test "localized message replaces non-breaking spaces" do
    I18n.backend.store_translations(:en, inbox: { nbsp_test: "hello&nbsp;world\u00A0!" })
    item = InboxItem.new(message_key: "inbox.nbsp_test", owner: users(:one), message_params: {})
    assert_equal "hello world !", item.localized_message(locale: :en)
  end

  test "localized message provides fallback for missing interpolation" do
    item = InboxItem.new(
      message_key: "inbox.comment_deleted_by_admin",
      owner: users(:one),
      message_params: { admin_name: "Admin User", creative_snippet: "Sample creative" }
    )

    assert_equal(
      "Admin User deleted your comment in \"Sample creative\": (comment unavailable)",
      item.localized_message(locale: :en)
    )
  end

  test "state is a string-backed enum with new/read/archived" do
    assert_equal({ "new" => "new", "read" => "read", "archived" => "archived" }, Collavre::InboxItem.states)
  end

  test "enum predicates and default" do
    item = InboxItem.create!(message_key: "inbox.no_messages", owner: users(:one), message_params: {})
    assert item.new?
    assert_equal "new", item.state
    item.read!
    assert item.read?
    assert_equal "read", item.reload.state
  end

  test "assigning an unknown state raises ArgumentError" do
    item = InboxItem.new(message_key: "inbox.no_messages", owner: users(:one), message_params: {})
    assert_raises(ArgumentError) { item.state = "bogus" }
  end

  test "new_items scope still selects only new" do
    InboxItem.create!(message_key: "inbox.no_messages", owner: users(:one), state: "read", message_params: {})
    assert InboxItem.new_items.all?(&:new?)
  end
end
