require "test_helper"

module Creatives
  class ChildrenIndexTest < ActiveSupport::TestCase
    test "candidate budget bounds SQL rows and permission checks across batches" do
      user = users(:one)
      roots = Array.new(2) { Creative.create!(user: user, description: "Root") }
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
      index = Collavre::Creatives::ChildrenIndex.new(user: user, show_archived: false, candidate_limit: 10)
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        PermissionFilter.stub(:new, filter) do
          roots.each { |root| index.index([ root ]) }
          index.index(roots)
        end
      end

      assert_equal children.first + children.last.first(2), checked
      assert_equal children.first, index.child_ids(roots.first)
      assert_equal children.last.first(2), index.child_ids(roots.last)
      assert_equal 2, queries.size
      assert queries.all? { |query| query[:sql].include?("LIMIT") }
      assert_equal 10, queries.sum { |query| query[:row_count] }

      other = Creative.create!(user: user, description: "Other")
      Creative.create!(user: user, parent: other, description: "Not inspected")
      PermissionFilter.stub(:new, ->(**) { flunk "Exhausted budget must not check more children" }) do
        index.index([ other ])
      end
      assert_empty index.child_ids(other)
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
