require "test_helper"

module Collavre
  class UserCreativePreferenceTest < ActiveSupport::TestCase
    test "expanded IDs place ancestors first regardless of save order" do
      root = Creative.create!(user: users(:one), description: "Root")
      child = Creative.create!(user: users(:one), parent: root, description: "Child")
      leaf = Creative.create!(user: users(:one), parent: child, description: "Leaf")
      preference = UserCreativePreference.new(user: users(:one), expanded_status: {
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

    test "archived saved branches do not consume the restoration limit" do
      assert_hidden_branches_do_not_displace_visible(user: users(:one), archived_at: Time.current)
    end

    test "unreadable saved branches do not consume the restoration limit" do
      assert_hidden_branches_do_not_displace_visible(user: users(:two))
    end

    test "readable shared branches remain eligible for restoration" do
      root = Creative.create!(user: users(:two), description: "Shared root")
      CreativeShare.create!(creative: root, user: users(:one), permission: :read)
      preference = UserCreativePreference.new(user: users(:one), expanded_status: { root.id.to_s => true })

      assert_equal [ root.id.to_s ], preference.expanded_ids_root_first
    end

    test "revoked access excludes a saved branch even when it is public" do
      root = Creative.create!(user: users(:two), description: "Shared root")
      CreativeShare.create!(creative: root, user: nil, permission: :read)
      share = CreativeShare.create!(creative: root, user: users(:one), permission: :read)
      preference = UserCreativePreference.new(user: users(:one), expanded_status: { root.id.to_s => true })
      assert_equal [ root.id.to_s ], preference.expanded_ids_root_first

      share.update!(permission: :no_access)

      assert_empty preference.expanded_ids_root_first
    end

    test "missing expansion status is empty" do
      assert_empty UserCreativePreference.new.expanded_ids_root_first
    end

    private

    def assert_hidden_branches_do_not_displace_visible(**hidden_attributes)
      hidden = Array.new(100) { Creative.create!(**hidden_attributes, description: "Hidden branch") }
      root = Creative.create!(user: users(:one), description: "Visible root")
      child = Creative.create!(user: users(:one), parent: root, description: "Visible child")
      status = hidden.to_h { |creative| [ creative.id.to_s, true ] }
      status.merge!(child.id.to_s => true, root.id.to_s => true)
      preference = UserCreativePreference.create!(user: users(:one), expanded_status: status)

      assert_equal [ root.id.to_s, child.id.to_s ], preference.expanded_ids_root_first.first(100)
      assert_equal status, preference.reload.expanded_status
    end
  end
end
