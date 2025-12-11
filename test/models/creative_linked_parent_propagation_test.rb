require "test_helper"

class CreativeLinkedParentPropagationTest < ActiveSupport::TestCase
  test "updates linked creative parent when origin is updated" do
    user = users(:one)

    # Structure:
    # A (Parent of Linked)
    #   -> B1_Linked (Linked to B1_Origin)
    # B (Parent of Origin)
    #   -> B1_Origin

    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user)

    b1_origin = Creative.create!(description: "B1 Origin", parent: b, user: user, progress: 0.0)
    b1_linked = Creative.create!(description: "B1 Linked", parent: a, user: user, origin: b1_origin)

    # Initial state
    a.reload
    b.reload
    assert_in_delta 0.0, a.progress, 0.001
    assert_in_delta 0.0, b.progress, 0.001

    # Update Origin
    b1_origin.update!(progress: 0.5)

    # Check if propagation happened
    b.reload
    assert_in_delta 0.5, b.progress, 0.001, "Origin Parent should update"

    a.reload
    # This currently fails because ProgressService thinks B1_Linked is already up to date (delegation) and doesn't fire update/callbacks
    assert_in_delta 0.5, a.progress, 0.001, "Linked Parent should update"
  end
end
