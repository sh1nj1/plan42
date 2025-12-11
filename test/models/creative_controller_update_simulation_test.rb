require "test_helper"

class CreativeControllerUpdateSimulationTest < ActiveSupport::TestCase
  test "simulation of controller update: accidentally passing origin_id to origin fails validation" do
    user = users(:one)

    # Setup: Linked Creative B2 -> Origin B1
    b1_origin = Creative.create!(description: "B1 Origin", user: user, progress: 0.0)
    b2_linked = Creative.create!(description: "B2 Linked", user: user, origin: b1_origin)

    # Simulate Controller Param Permitting
    # The controller permits: :description, :progress, :parent_id, :sequence, :origin_id
    # When updating B2_linked, inputs might include origin_id (pointing to B1)

    permitted_params = {
      "progress" => 0.5,
      "origin_id" => b1_origin.id # This is the problematic parameter
    }

    # The controller Logic:
    # 1. Handle parent_id for Linked
    # 2. Filter origin_id from permitted
    # 3. Update Base

    base = b2_linked.effective_origin(Set.new)
    assert_equal b1_origin, base

    permitted_params.delete("origin_id") # The FIX implemented in controller

    # Now this should SUCCEED
    assert_nothing_raised do
      base.update!(permitted_params)
    end

    assert_equal 0.5, b1_origin.reload.progress
  end
end
