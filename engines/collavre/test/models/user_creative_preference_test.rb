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
      Creative.create!(user: users(:one), parent: child, description: "Leaf")
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
      Creative.create!(user: users(:two), parent: root, description: "Shared child")
      CreativeShare.create!(creative: root, user: users(:one), permission: :read)
      shell = Creative.create!(user: users(:one), origin: root)
      preference = UserCreativePreference.new(user: users(:one), expanded_status: { shell.id.to_s => true })

      assert_equal [ shell.id.to_s ], preference.expanded_ids_root_first
    end

    test "revoked access excludes a saved branch even when it is public" do
      root = Creative.create!(user: users(:two), description: "Shared root")
      Creative.create!(user: users(:two), parent: root, description: "Shared child")
      CreativeShare.create!(creative: root, user: nil, permission: :read)
      share = CreativeShare.create!(creative: root, user: users(:one), permission: :read)
      shell = Creative.create!(user: users(:one), origin: root)
      preference = UserCreativePreference.new(user: users(:one), expanded_status: { shell.id.to_s => true })
      assert_equal [ shell.id.to_s ], preference.expanded_ids_root_first

      share.update!(permission: :no_access)

      assert_empty preference.expanded_ids_root_first
    end

    test "linked descendants follow their deeper workspace shells at the client limit" do
      origin = Creative.create!(user: users(:two), description: "Origin")
      child = Creative.create!(user: users(:two), parent: origin, description: "Origin child")
      Creative.create!(user: users(:two), parent: child, description: "Origin leaf")
      CreativeShare.create!(creative: origin, user: users(:one), permission: :read)
      root = Creative.create!(user: users(:one), description: "Root")
      parent = Creative.create!(user: users(:one), parent: root, description: "Parent")
      shell = Creative.create!(user: users(:one), parent: parent, origin: origin)
      siblings = Array.new(97) { Creative.create!(user: users(:one), parent: root, description: "Sibling") }
      siblings.each { |sibling| Creative.create!(user: users(:one), parent: sibling, description: "Leaf") }
      saved = [ child, shell, parent, *siblings, root ].to_h { |creative| [ creative.id.to_s, true ] }
      preference = UserCreativePreference.new(user: users(:one), expanded_status: saved)

      ordered = preference.expanded_ids_root_first
      assert_equal 101, ordered.size
      assert_operator ordered.index(shell.id.to_s), :<, ordered.index(child.id.to_s)
      assert_includes ordered.first(100), shell.id.to_s
      assert_not_includes ordered.first(100), child.id.to_s
    end

    test "nested links restore in rendered order and terminate cycles" do
      root = Creative.create!(user: users(:one), description: "Root")
      first_origin = Creative.create!(user: users(:two), description: "First origin")
      second_origin = Creative.create!(user: users(:two), description: "Second origin")
      [ first_origin, second_origin ].each do |origin|
        CreativeShare.create!(creative: origin, user: users(:one), permission: :read)
      end
      shell = Creative.create!(user: users(:one), parent: root, origin: first_origin)
      nested = Creative.create!(user: users(:one), parent: first_origin, origin: second_origin)
      cycle = Creative.create!(user: users(:one), parent: second_origin, origin: first_origin)
      saved = [ cycle, nested, shell, root ].to_h { |creative| [ creative.id.to_s, true ] }
      preference = UserCreativePreference.new(user: users(:one), expanded_status: saved)

      assert_equal [ root, shell, nested, cycle ].map { |creative| creative.id.to_s },
                   preference.expanded_ids_root_first
    end

    test "saved descendants of collapsed or archived ancestors do not consume the limit" do
      root = Creative.create!(user: users(:one), description: "Root")
      child = Creative.create!(user: users(:one), parent: root, description: "Child")
      preference = UserCreativePreference.new(user: users(:one), expanded_status: { child.id.to_s => true })
      assert_empty preference.expanded_ids_root_first

      preference.expanded_status[root.id.to_s] = true
      root.update!(archived_at: Time.current)
      assert_empty preference.expanded_ids_root_first
    end

    test "formerly expanded leaves do not displace a live branch from the restoration limit" do
      root = Creative.create!(user: users(:one), description: "Root")
      stale = Array.new(99) do
        branch = Creative.create!(user: users(:one), parent: root, description: "Former branch")
        child = Creative.create!(user: users(:two), parent: branch, description: "Former child")
        CreativeShare.create!(creative: child, user: users(:one), permission: :read)
        [ branch, child ]
      end
      live = Creative.create!(user: users(:one), parent: root, description: "Live branch")
      Creative.create!(user: users(:one), parent: live, description: "Unsaved leaf")
      status = [ root, *stale.map(&:first), live ].to_h { |creative| [ creative.id.to_s, true ] }
      preference = UserCreativePreference.create!(user: users(:one), expanded_status: status)

      stale.each_with_index do |(_branch, child), index|
        case index % 3
        when 0 then child.update!(parent: live)
        when 1 then child.update!(archived_at: Time.current)
        when 2 then CreativeShare.find_by!(creative: child, user: users(:one)).update!(permission: :no_access)
        end
      end

      assert_equal [ root.id.to_s, live.id.to_s ], preference.expanded_ids_root_first.first(100)
      assert_equal status, preference.reload.expanded_status
    end

    test "missing expansion status is empty" do
      assert_empty UserCreativePreference.new.expanded_ids_root_first
    end

    private

    def assert_hidden_branches_do_not_displace_visible(**hidden_attributes)
      hidden = Array.new(100) { Creative.create!(**hidden_attributes, description: "Hidden branch") }
      root = Creative.create!(user: users(:one), description: "Visible root")
      child = Creative.create!(user: users(:one), parent: root, description: "Visible child")
      Creative.create!(user: users(:one), parent: child, description: "Visible leaf")
      status = hidden.to_h { |creative| [ creative.id.to_s, true ] }
      status.merge!(child.id.to_s => true, root.id.to_s => true)
      preference = UserCreativePreference.create!(user: users(:one), expanded_status: status)

      assert_equal [ root.id.to_s, child.id.to_s ], preference.expanded_ids_root_first.first(100)
      assert_equal status, preference.reload.expanded_status
    end
  end
end
