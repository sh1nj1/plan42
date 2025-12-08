require "test_helper"

class CreativeMoveProgressTest < ActiveSupport::TestCase
  test "updates old parent progress when child is moved" do
    # User setup
    user = users(:one)

    # Setup structure:
    # A (root)
    # B (root)
    #   -> B1 (progress: 1.0)
    #   -> B2 (progress: 0.0)
    #
    # Initial B progress should be 0.5

    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user)

    b1 = Creative.create!(description: "B1", parent: b, user: user, progress: 1.0)
    b2 = Creative.create!(description: "B2", parent: b, user: user, progress: 0.0)

    # Reload B to check calculated progress
    b.reload
    assert_in_delta 0.5, b.progress, 0.001, "Initial progress for B should be 0.5 (average of 1.0 and 0.0)"

    # Action: Move B2 to A
    # Structure becomes:
    # A (root)
    #   -> B2 (progress: 0.0)
    # B (root)
    #   -> B1 (progress: 1.0)
    #
    # Expected result:
    # B.progress becomes 1.0 (average of just B1)

    b2.update!(parent: a)

    # Reload B to check updated progress
    b.reload

    # This assertion is expected to fail currently
    assert_in_delta 1.0, b.progress, 0.001, "After moving B2 out, B progress should be 1.0 (average of just B1)"

    # Optional: Check A's progress too, though that probably works
    a.reload
    assert_in_delta 0.0, a.progress, 0.001, "A progress should be 0.0 (average of just B2)"
  end
end
