require "test_helper"

module Creatives
  class ChildrenIndexTest < ActiveSupport::TestCase
    test "candidate budget reserves later parent probes and bounds SQL rows across batches" do
      user = users(:one)
      roots = Array.new(4) { Creative.create!(user: user, description: "Root") }
      children = roots.map do |root|
        Creative.insert_all!(Array.new(8) do |sequence|
          { user_id: user.id, parent_id: root.id, description: "Child", sequence: sequence }
        end).rows.flatten
      end
      checked = []
      filter = PermissionFilter.new(user: user)
      original = filter.method(:readable_ids)
      filter.define_singleton_method(:readable_ids) do |ids|
        checked.concat(ids)
        original.call(ids)
      end
      queries = []
      subscriber = lambda do |event|
        queries << event.payload if event.payload[:sql].include?('"creatives"."parent_id"') &&
          event.payload[:sql].start_with?("SELECT")
      end
      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: false, candidate_limit: 3)
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        PermissionFilter.stub(:new, filter) do
          roots.each { |root| index.index([ root ]) }
          index.index(roots)
        end
      end

      assert_equal children.first.first(4) + children[1].first(1) + children[2].first(1), checked
      assert_equal children.first.first(4), index.child_ids(roots.first)
      assert_equal children[2].first(1), index.child_ids(roots[2])
      assert_equal 3, queries.size
      assert queries.all? { |query| query[:sql].include?("LIMIT") }
      assert_equal 6, queries.sum { |query| query[:row_count] }

      other = Creative.create!(user: user, description: "Other")
      Creative.create!(user: user, parent: other, description: "Not inspected")
      PermissionFilter.stub(:new, ->(**) { flunk "Exhausted budget must not check more children" }) do
        index.index([ other ])
      end
      assert_empty index.child_ids(other)
    end

    test "candidate IDs are filtered in SQL before the cumulative limit" do
      user = users(:one)
      root = Creative.create!(user: user, description: "Root")
      ids = Creative.insert_all!(Array.new(1_050) do |sequence|
        { user_id: user.id, parent_id: root.id, description: "Child", sequence: sequence }
      end).rows.flatten
      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: false,
        candidate_limit: 1, candidate_ids: ids.last(3))
      filter = Minitest::Mock.new
      filter.expect(:readable_ids, ids.last(3).first(2), [ ids.last(3).first(2) ])
      queries = []
      subscriber = ->(event) { queries << event.payload if event.payload[:sql].include?('"creatives"."parent_id"') }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        PermissionFilter.stub(:new, filter) { index.index([ root ]) }
      end

      assert_equal ids.last(3).first(2), index.child_ids(root)
      assert_equal 2, queries.sum { |query| query[:row_count] }
      assert queries.first[:sql].include?("LIMIT")
      filter.verify
    end

    test "saved candidate allowance is shared fairly between origins in a level" do
      user = users(:one)
      roots = Array.new(2) { Creative.create!(user: user, description: "Root") }
      roots.each do |root|
        Creative.insert_all!(Array.new(8) do |sequence|
          { user_id: user.id, parent_id: root.id, description: "Child", sequence: sequence }
        end)
      end
      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: false, candidate_limit: 10)
      index.index(roots)

      roots.each { |root| assert_equal root.children.order(:sequence, :id).limit(6).pluck(:id), index.child_ids(root) }
    end

    test "empty and linked origins preserve remaining candidate allowance" do
      user = users(:one)
      empty = Creative.create!(user: user, description: "Empty")
      origin = Creative.create!(user: user, description: "Origin")
      shell = Creative.create!(user: user, origin: origin)
      children = Array.new(3) { Creative.create!(user: user, parent: origin, description: "Child") }
      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: false, candidate_limit: 2)
      index.index([ empty, origin, shell ])

      assert_empty index.child_ids(empty)
      assert_equal children.map(&:id), index.child_ids(origin)
      assert_equal index.child_ids(origin), index.child_ids(shell)
    end

    test "normal rendering does not truncate children and retains archive filtering" do
      user = users(:one)
      root = Creative.create!(user: user, description: "Root")
      visible = Creative.create!(user: user, parent: root, description: "Visible")
      archived = Creative.create!(user: user, parent: root, description: "Archived", archived_at: Time.current)
      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: false)
      index.index([ root ])
      assert_equal [ visible.id ], index.child_ids(root)

      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: true)
      index.index([ root ])
      assert_equal [ visible.id, archived.id ], index.child_ids(root)
    end
  end
end
