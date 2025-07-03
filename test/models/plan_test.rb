require "test_helper"

class PlanTest < ActiveSupport::TestCase
  test "progress averages tagged trees" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    root1 = Creative.create!(user: user, description: "Root1", progress: 0)
    child1 = Creative.create!(user: user, parent: root1, description: "Child1", progress: 0.2)
    child2 = Creative.create!(user: user, parent: root1, description: "Child2", progress: 0.8)

    root2 = Creative.create!(user: user, description: "Root2", progress: 0)
    child3 = Creative.create!(user: user, parent: root2, description: "Child3", progress: 0.7)

    plan = Plan.create!(name: "P", target_date: Date.today, owner: user)
    Tag.create!(creative_id: child1.id, label: plan)
    Tag.create!(creative_id: child2.id, label: plan)
    Tag.create!(creative_id: child3.id, label: plan)

    assert_in_delta 0.6, plan.progress, 0.001

    Current.reset
  end
end
