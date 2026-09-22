require "test_helper"

module Collavre
  module Creatives
    class WorkspaceExpansionPresenceTest < ActiveSupport::TestCase
      test "presence SQL rows and permission checks are bounded independently for each branch" do
        user = users(:one)
        roots = Array.new(2) { Creative.create!(user: user, description: "Root") }
        roots.each do |root|
          Creative.insert_all!(Array.new(200) do |sequence|
            { user_id: user.id, parent_id: root.id, description: "Child", sequence: sequence }
          end)
        end
        checked = []
        filter = Object.new
        filter.define_singleton_method(:readable_ids) { |ids| checked.concat(ids); [] }
        presence = PermissionFilter.stub(:new, filter) { WorkspaceExpansionPresence.new(user: user, limit: 150) }
        queries = []
        subscriber = lambda do |event|
          queries << event.payload if event.payload[:sql].start_with?("SELECT") &&
            event.payload[:sql].include?('"creatives"."parent_id"')
        end
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          roots.each { |root| assert_not presence.visible_child?(root, excluding: Set.new) }
        end

        assert_equal 300, checked.uniq.size
        assert_equal [ 1, 100, 49, 1, 100, 49 ], queries.map { |query| query[:row_count] }
        assert queries.all? { |query| query[:sql].include?("LIMIT") }
      end

      test "presence excludes archived children and path cycles and follows linked origins" do
        user = users(:one)
        origin = Creative.create!(user: user, description: "Origin")
        shell = Creative.create!(user: user, origin: origin)
        child = Creative.create!(user: user, parent: origin, description: "Child")
        Creative.create!(user: user, parent: origin, description: "Archived", archived_at: Time.current)
        presence = WorkspaceExpansionPresence.new(user: user, limit: 10)

        assert_not presence.visible_child?(shell, excluding: Set[child.id])
        assert presence.visible_child?(shell, excluding: Set.new)
      end

      test "presence skips unreadable children before a readable child in the next batch" do
        user = users(:one)
        root = Creative.create!(user: user, description: "Root")
        Creative.insert_all!(Array.new(100) do |sequence|
          { user_id: users(:two).id, parent_id: root.id, description: "Hidden", sequence: sequence }
        end)
        Creative.create!(user: user, parent: root, description: "Visible", sequence: 101)
        presence = WorkspaceExpansionPresence.new(user: user, limit: 101)

        assert presence.visible_child?(root, excluding: Set.new)
      end
    end
  end
end
