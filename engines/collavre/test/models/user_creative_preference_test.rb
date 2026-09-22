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
      assert_equal 100, ordered.size
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

      assert_equal [ root, shell, nested ].map { |creative| creative.id.to_s },
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

    test "restoration stops at 100 roots in workspace sequence order before indexing descendants" do
      roots = Array.new(110) do
        root = Creative.create!(user: users(:one), description: "Root")
        child = Creative.create!(user: users(:one), parent: root, description: "Branch")
        Creative.create!(user: users(:one), parent: child, description: "Leaf")
        [ root, child ]
      end
      roots.last.first.update_column(:sequence, -1)
      saved = roots.flatten.to_h { |creative| [ creative.id.to_s, true ] }
      preference = UserCreativePreference.new(user: users(:one), expanded_status: saved)
      indexed = []
      index = Creatives::ChildrenIndex.new(user: users(:one), show_archived: false)
      original_index = index.method(:index)
      index.define_singleton_method(:index) do |creatives|
        indexed.concat(creatives.map(&:id))
        original_index.call(creatives)
      end

      ordered = Creatives::ChildrenIndex.stub(:new, index) { preference.expanded_ids_root_first }

      expected = Creative.where(id: roots.map { |root, _| root.id }).roots.limit(100).pluck(:id)
      assert_equal expected.map(&:to_s), ordered
      assert_equal roots.last.first.id.to_s, ordered.first
      assert_equal expected.sort, indexed.sort
    end

    test "unsaved siblings cannot displace a late saved branch from restoration" do
      user = users(:one)
      root = Creative.create!(user: user, description: "Root")
      Creative.insert_all!(Array.new(1_050) do |sequence|
        { user_id: user.id, parent_id: root.id, description: "Unsaved sibling", sequence: sequence }
      end)
      child = Creative.create!(user: user, parent: root, description: "Saved branch", sequence: 1_051)
      Creative.create!(user: user, parent: child, description: "Unsaved leaf")
      preference = UserCreativePreference.new(user: user, expanded_status: {
        root.id.to_s => true, child.id.to_s => true
      })

      assert_equal [ root.id.to_s, child.id.to_s ], preference.expanded_ids_root_first
    end

    test "stale saved children cannot exhaustively scan beyond the inspection budget" do
      assert_stale_inspection_bound(nested: true)
    end

    test "stale saved roots cannot exhaustively scan beyond the inspection budget" do
      assert_stale_inspection_bound(nested: false)
    end

    test "cycle terminal shells leave room for a later live branch" do
      root = Creative.create!(user: users(:one), description: "Root")
      origin = Creative.create!(user: users(:two), description: "Origin")
      CreativeShare.create!(creative: origin, user: users(:one), permission: :read)
      shell = Creative.create!(user: users(:one), parent: root, origin: origin)
      terminal = Creative.create!(user: users(:one), parent: origin, origin: origin)
      siblings = Array.new(97) do
        branch = Creative.create!(user: users(:one), parent: root, description: "Branch")
        Creative.create!(user: users(:one), parent: branch, description: "Leaf")
        branch
      end
      # This branch is visited after the cycle-terminal shell, at the same depth.
      live = Creative.create!(user: users(:one), parent: siblings.last, description: "Live")
      Creative.create!(user: users(:one), parent: live, description: "Leaf")
      saved = [ root, shell, terminal, *siblings, live ].to_h { |creative| [ creative.id.to_s, true ] }
      preference = UserCreativePreference.new(user: users(:one), expanded_status: saved)

      ordered = preference.expanded_ids_root_first

      assert_equal 100, ordered.size
      assert_not_includes ordered, terminal.id.to_s
      assert_includes ordered, live.id.to_s
    end

    test "missing expansion status is empty" do
      assert_empty UserCreativePreference.new.expanded_ids_root_first
    end

    test "root restoration handles missing and empty state and uses later duplicate values" do
      user = users(:one)
      UserCreativePreference.where(user: user, creative_id: nil).delete_all
      assert_empty UserCreativePreference.root_expanded_ids_for(user)

      root = Creative.create!(user: user, description: "Root")
      Creative.create!(user: user, parent: root, description: "Child")
      first = UserCreativePreference.create!(user: user, expanded_status: { root.id.to_s => true })
      empty_state = UserCreativePreference.create!(user: user, expanded_status: { "stale" => true })
      empty_state.update_column(:expanded_status, {})
      assert_equal [ root.id.to_s ], UserCreativePreference.root_expanded_ids_for(user)

      UserCreativePreference.create!(user: user, expanded_status: { root.id.to_s => false })
      assert_empty UserCreativePreference.root_expanded_ids_for(user)
      assert_equal({ root.id.to_s => true }, first.reload.expanded_status)
      assert_empty empty_state.reload.expanded_status
    end

    private

    def assert_stale_inspection_bound(nested:)
      user = users(:one)
      root = Creative.create!(user: user, description: "Root") if nested
      limit = Creatives::WorkspaceExpansionOrder::INSPECTION_LIMIT
      leaves = Creative.insert_all!(Array.new(limit + 50) do |index|
        { user_id: user.id, parent_id: root&.id, description: "Stale leaf", sequence: index }
      end).rows.flatten
      saved = [ root&.id, *leaves ].compact.to_h { |id| [ id.to_s, true ] }
      preference = UserCreativePreference.create!(user: user, expanded_status: saved)
      indexed = []
      index = Creatives::ChildrenIndex.new(user: user, show_archived: false, candidate_limit: limit)
      inspected_children = []
      original_children = index.method(:visible_child_ids_by_origin)
      index.define_singleton_method(:visible_child_ids_by_origin) do |rows|
        inspected_children.concat(rows.map(&:first))
        original_children.call(rows)
      end
      original_index = index.method(:index)
      index.define_singleton_method(:index) do |creatives|
        indexed.concat(creatives.map(&:id))
        original_index.call(creatives)
      end

      restored = Creatives::ChildrenIndex.stub(:new, index) { preference.expanded_ids_root_first }

      assert_equal(root ? [ root.id.to_s ] : [], restored)
      assert_equal limit, indexed.size
      assert_equal(root ? limit : 0, inspected_children.size)
      assert_not_includes inspected_children, leaves.last
      assert_not_includes indexed, leaves.last
      assert_equal saved, preference.reload.expanded_status
    end


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
