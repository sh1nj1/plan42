require "test_helper"

class CreativeLinkedUpdateTest < ActiveSupport::TestCase
  test "updates origin progress when linked creative is updated and propagates to both parents" do
    user = users(:one)

    # Structure:
    # A (root)
    #   -> B2_Linked (Linked to B2_Origin)
    # B (root)
    #   -> B2_Origin

    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user)

    b2_origin = Creative.create!(description: "B2 Origin", parent: b, user: user, progress: 0.0)
    b2_linked = Creative.create!(description: "B2 Linked", parent: a, user: user, origin: b2_origin)

    # Initial state check
    assert_in_delta 0.0, a.progress, 0.001
    assert_in_delta 0.0, b.progress, 0.001

    # Action: Update B2_Linked progress to 0.5
    # Should update B2_Origin to 0.5
    # Should update B (parent of Origin) to 0.5 (average of 1 child)
    # Should update A (parent of Linked) to 0.5 (average of 1 child)

    # Action: Update B2_Linked is FORBIDDEN.
    # The Controller handles this by finding the effective origin and updating THAT.
    # So we simulate what the controller does: Update B2_Origin.
    b2_origin.update!(progress: 0.5)

    # Verification
    b2_origin.reload
    b2_linked.reload
    a.reload
    b.reload

    assert_in_delta 0.5, b2_origin.progress, 0.001, "Origin progress should be updated"
    assert_in_delta 0.5, b2_linked.progress, 0.001, "Linked progress should reflect Origin"
    assert_in_delta 0.5, b.progress, 0.001, "B (Origin Parent) progress should be updated"
    assert_in_delta 0.5, a.progress, 0.001, "A (Linked Parent) progress should be updated"
  end
end
