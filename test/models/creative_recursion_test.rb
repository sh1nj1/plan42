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
end
