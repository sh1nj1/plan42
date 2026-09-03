# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class ChangeSetDiffTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @root = Creative.create!(description: "Root", user: @user)
        @child = Creative.create!(description: "<p>New &lt;value&gt;</p>", user: @user, parent: @root)
        @change_set = CreativeChangeSet.create!(
          anchor_creative: @root,
          anchor_source: "view_root",
          user: @user,
          actor_kind: "human",
          origin: "editor",
          status: "applied",
          applied_at: Time.current
        )
        @change_set.creative_changes.create!(
          creative: @child,
          operation: "update",
          before: History.snapshot(@child).merge("description" => "<p>Old &lt;value&gt;</p>"),
          after: History.snapshot(@child),
          position: 0
        )
      end

      test "renders changes under the observed anchor as one document diff" do
        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole

        assert_equal @root.id, group.fetch(:root_id)
        assert_equal "Root", group.fetch(:label)
        assert_includes group.fetch(:before), "Old &lt;value&gt;"
        assert_includes group.fetch(:after), "New &lt;value&gt;"
        assert_includes group.fetch(:inline_html), "<del>Old</del>"
        assert_includes group.fetch(:inline_html), "&amp;lt;"
        assert_equal 1, group.fetch(:additions)
        assert_equal 1, group.fetch(:deletions)
      end

      test "renders touched roots outside the anchor as separate groups" do
        outside = Creative.create!(description: "Outside", user: @user)
        @change_set.creative_changes.create!(
          creative: outside,
          operation: "update",
          before: History.snapshot(outside).merge("description" => "Before"),
          after: History.snapshot(outside),
          position: 1
        )

        assert_equal [ @child.id, outside.id ].sort,
                     ChangeSetDiff.new(@change_set, user: @user).groups.pluck(:root_id).sort
      end

      test "treats a Creative moved to the tree root as outside the anchor" do
        change = @change_set.creative_changes.sole
        change.update!(
          operation: "move",
          before: change.before.merge("parent_id" => @root.id),
          after: change.after.merge("parent_id" => nil)
        )
        @child.update!(parent: nil)

        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole
        assert_equal @child.id, group.fetch(:root_id)
        assert group.fetch(:moved)
      end

      test "reconstructs created and removed nodes from snapshots" do
        created = Creative.create!(description: "Created", user: @user, parent: @root)
        @change_set.creative_changes.create!(
          creative: created,
          operation: "create",
          before: {},
          after: History.snapshot(created),
          position: 1
        )

        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole
        assert_not_includes group.fetch(:before), "Created"
        assert_includes group.fetch(:after), "Created"
        assert group.fetch(:split_rows).any? { |row| row.fetch(:action) != "=" }
      end

      test "filters changes outside the viewer's permission boundary" do
        foreign = Creative.create!(description: "Foreign secret", user: users(:two))
        @change_set.creative_changes.create!(
          creative: foreign,
          operation: "update",
          before: History.snapshot(foreign).merge("description" => "Earlier secret"),
          after: History.snapshot(foreign),
          position: 1
        )

        diff = ChangeSetDiff.new(@change_set, user: @user)
        rendered = diff.groups.to_json

        assert_not_includes rendered, "Foreign secret"
        assert_not_includes rendered, "Earlier secret"
        assert_equal 1, diff.change_count
        assert_not diff.fully_visible?
      end

      test "keeps a destroyed descendant visible through its readable former parent" do
        change = @change_set.creative_changes.sole
        before = change.before.merge("parent_id" => @root.id, "description" => "Removed child")
        change.update!(operation: "destroy", before: before, after: {}, previous_parent_id: @root.id)
        @child.destroy!

        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole

        assert_includes group.fetch(:before), "Removed child"
        assert_not_includes group.fetch(:after), "Removed child"
      end

      test "does not infer permission to a deleted snapshot from its former parent" do
        reader = users(:two)
        root_share = CreativeShare.create!(
          creative: @root, user: reader, shared_by: @user, permission: :read
        )
        deny = CreativeShare.create!(
          creative: @child, user: reader, shared_by: @user, permission: :no_access
        )
        PermissionCacheBuilder.propagate_share(root_share)
        PermissionCacheBuilder.propagate_share(deny)
        change = @change_set.creative_changes.sole
        change.update!(
          operation: "destroy",
          before: change.before.merge("parent_id" => @root.id, "description" => "Removed secret"),
          after: {},
          previous_parent_id: @root.id
        )
        @child.destroy!

        diff = ChangeSetDiff.new(@change_set, user: reader)

        assert_empty diff.groups
        assert_equal 0, diff.change_count
      end
    end
  end
end
