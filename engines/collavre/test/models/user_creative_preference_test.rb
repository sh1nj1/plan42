require "test_helper"

module Collavre
  class UserCreativePreferenceTest < ActiveSupport::TestCase
    test "expanded IDs place ancestors first regardless of save order" do
      root = Creative.create!(user: users(:one), description: "Root")
      child = Creative.create!(user: users(:one), parent: root, description: "Child")
      leaf = Creative.create!(user: users(:one), parent: child, description: "Leaf")
      preference = UserCreativePreference.new(expanded_status: {
        child.id.to_s => true, root.id.to_s => true, leaf.id.to_s => false
      })

      assert_equal [ root.id.to_s, child.id.to_s ], preference.expanded_ids_root_first
    end

    test "deleted expanded IDs do not displace live branches from the client limit" do
      root = Creative.create!(user: users(:one), description: "Root")
      child = Creative.create!(user: users(:one), parent: root, description: "Child")
      deleted = Creative.create!(user: users(:one), description: "Deleted")
      stale_ids = (1..100).to_h { |index| [ (-index).to_s, true ] }
      preference = UserCreativePreference.create!(user: users(:one), expanded_status: stale_ids.merge(
        deleted.id.to_s => true, child.id.to_s => true, root.id.to_s => true
      ))
      deleted.destroy!

      assert preference.reload.expanded_status.key?(deleted.id.to_s)
      assert_equal [ root.id.to_s, child.id.to_s ], preference.expanded_ids_root_first.first(100)
    end

    test "missing expansion status is empty" do
      assert_empty UserCreativePreference.new.expanded_ids_root_first
    end
  end
end
