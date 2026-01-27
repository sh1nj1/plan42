require "test_helper"

class CreativeLinkedProgressTest < ActiveSupport::TestCase
  test "linked creative progress update propagates to its parent" do
    # A -> AA (Origin)
    # B -> AA' (Linked)

    user = User.create!(email: "test@example.com", password: "password", name: "Test User")

    # Create Origin Hierarchy
    origin_parent = Creative.create!(description: "Origin Parent", progress: 0.0, user: user)
    origin = Creative.create!(description: "Origin", parent: origin_parent, progress: 0.0, user: user)

    # Create Linked Hierarchy
    linked_parent = Creative.create!(description: "Linked Parent", progress: 0.0, user: user)
    linked = Creative.create!(description: "Linked", parent: linked_parent, origin: origin, user: user)

    # Initial State
    assert_equal 0.0, origin.progress
    assert_equal 0.0, linked.progress
    assert_equal 0.0, linked_parent.progress

    # Update Origin Progress
    origin.update!(progress: 0.5)

    # Verify Linked Creative Updated
    linked.reload
    assert_equal 0.5, linked.progress, "Linked creative should have updated progress"

    # Verify Linked Parent Updated
    linked_parent.reload
    assert_equal 0.5, linked_parent.progress, "Linked parent should have updated progress from linked child"
  end
end
