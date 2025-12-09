require "test_helper"

class CreativeRecursionTest < ActiveSupport::TestCase
  test "effective_attribute handles circular origin references gracefully" do
    user = users(:one)

    # Setup Cycle: A -> B -> A
    # Calling A.progress should not crash

    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user)

    # We need to bypass validation/checks to create a cycle usually,
    # or just set up origin_id directly.

    a.update_columns(origin_id: b.id)
    b.update_columns(origin_id: a.id)

    # Reload to ensure associations are fresh
    a.reload
    b.reload

    # This should return nil or self value, but NOT crash
    assert_nothing_raised do
      a.progress
    end
  end

  test "avoids infinite loop when updating linked creative with propagation" do
    user = users(:one)

    # Scenario from previous bug, ensuring stability
    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user)

    b2_origin = Creative.create!(description: "B2 Origin", parent: b, user: user, progress: 0.0)
    b2_linked = Creative.create!(description: "B2 Linked", parent: a, user: user, origin: b2_origin)

    # Force updates to verify no recursion
    assert_nothing_raised do
      b2_linked.update!(progress: 0.5)
    end

    assert_in_delta 0.5, b2_origin.reload.progress, 0.001

    # Also verify reverse update (Origin -> Linked)
    assert_nothing_raised do
      b2_origin.update!(progress: 0.8)
    end

    assert_in_delta 0.8, b2_linked.reload.progress, 0.001
  end
end
