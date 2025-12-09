require "test_helper"

class CreativeUpdateCycleTest < ActiveSupport::TestCase
  test "prevents infinite loop when updating linked creatives in a cycle" do
    user = users(:one)

    # Structure:
    # A (Origin)
    # B (Linked to A)
    #
    # If we update A, it updates B.
    # B's callbacks update A (propagation to origin).
    # This creates a loop if not guarded.

    a = Creative.create!(description: "A", user: user, progress: 0.0)
    b = Creative.create!(description: "B", user: user, origin: a, progress: 0.0)

    # Trigger update on A
    assert_nothing_raised do
      a.update!(progress: 0.5)
    end

    assert_in_delta 0.5, b.reload.progress, 0.001

    # Trigger update on B
    assert_nothing_raised do
      b.update!(progress: 0.8)
    end

    assert_in_delta 0.8, a.reload.progress, 0.001
  end
end
