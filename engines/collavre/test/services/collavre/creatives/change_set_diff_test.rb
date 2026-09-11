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

      test "renders only changed hunks with surrounding context for a large document" do
        before_lines = Array.new(400) { |index| "line #{index}" }
        after_lines = before_lines.dup
        after_lines[200] = "line 200 edited"
        large = Creative.create!(
          description: after_lines.join("\n"), user: @user, parent: @root,
          data: { "content_type" => "markdown", "markdown_source" => after_lines.join("\n") }
        )
        @change_set.creative_changes.create!(
          creative: large, operation: "update",
          before: History.snapshot(large).merge("markdown_source" => before_lines.join("\n")),
          after: History.snapshot(large), position: 1
        )

        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole
        rows = group.fetch(:split_rows)

        assert_operator rows.size, :<, 40, "unchanged lines must not be rendered"
        assert rows.any? { |row| row.fetch(:after).include?("line 200 edited") }
        assert_not rows.any? { |row| row.fetch(:before).include?("line 10 ") || row.fetch(:before).strip == "line 10" }
        assert_not_includes group.fetch(:inline_html), "line 10\n"
        assert_includes group.fetch(:inline_html), "edited"
      end

      test "marks elided regions with a gap row carrying the skipped line count" do
        before_lines = Array.new(400) { |index| "line #{index}" }
        after_lines = before_lines.dup
        after_lines[200] = "line 200 edited"
        large = Creative.create!(
          description: after_lines.join("\n"), user: @user, parent: @root,
          data: { "content_type" => "markdown", "markdown_source" => after_lines.join("\n") }
        )
        @change_set.creative_changes.create!(
          creative: large, operation: "update",
          before: History.snapshot(large).merge("markdown_source" => before_lines.join("\n")),
          after: History.snapshot(large), position: 1
        )

        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole
        gaps = group.fetch(:split_rows).select { |row| row.fetch(:action) == ChangeSetDiff::GAP_ACTION }

        rendered = group.fetch(:split_rows).size - gaps.size
        assert_operator gaps.size, :>=, 2
        assert gaps.all? { |gap| gap.fetch(:skipped).positive? }
        # Every line of the document is either rendered or accounted for by a gap.
        assert_equal group.fetch(:after).lines.size,
                     rendered + gaps.sum { |gap| gap.fetch(:skipped) }
        assert_includes group.fetch(:inline_html),
                        I18n.t("collavre.creative_history.skipped_lines", count: gaps.first.fetch(:skipped))
      end

      test "still counts additions and deletions across the whole document" do
        before_lines = Array.new(400) { |index| "line #{index}" }
        after_lines = before_lines.dup
        after_lines[10] = "line 10 edited"
        after_lines[300] = "line 300 edited"
        large = Creative.create!(
          description: after_lines.join("\n"), user: @user, parent: @root,
          data: { "content_type" => "markdown", "markdown_source" => after_lines.join("\n") }
        )
        @change_set.creative_changes.create!(
          creative: large, operation: "update",
          before: History.snapshot(large).merge("markdown_source" => before_lines.join("\n")),
          after: History.snapshot(large), position: 1
        )

        group = ChangeSetDiff.new(@change_set, user: @user).groups.sole

        # Two edited lines here plus the single-line edit recorded in setup.
        assert_equal 3, group.fetch(:additions)
        assert_equal 3, group.fetch(:deletions)
      end

      test "converts an untouched node to markdown once across both document states" do
        4.times { |index| Creative.create!(description: "<p>Stable #{index}</p>", user: @user, parent: @root) }
        conversions = Hash.new(0)
        converter = MarkdownConverter.method(:html_to_markdown)
        counting = lambda do |html|
          conversions[html] += 1
          converter.call(html)
        end
        group = MarkdownConverter.stub(:html_to_markdown, counting) do
          ChangeSetDiff.new(@change_set, user: @user).groups.sole
        end

        assert_includes group.fetch(:before), "Stable 0"
        # before and after rebuild the same document; untouched nodes convert once.
        assert_equal 1, conversions["<p>Stable 0</p>"]
        assert_equal 1, conversions["<p>Stable 3</p>"]
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

      test "bulk loads candidate descendants once for both document states" do
        3.times do |index|
          child = Creative.create!(description: "Child #{index}", user: @user, parent: @root)
          @change_set.creative_changes.create!(
            creative: child, operation: "update",
            before: History.snapshot(child).merge("description" => "Before #{index}"),
            after: History.snapshot(child), position: index + 1
          )
        end
        outside = Creative.create!(description: "Outside", user: @user)
        @change_set.creative_changes.create!(
          creative: outside, operation: "update",
          before: History.snapshot(outside).merge("description" => "Earlier outside"),
          after: History.snapshot(outside), position: 4
        )
        descendant_queries = []
        callback = lambda do |_name, _start, _finish, _id, payload|
          sql = payload[:sql].to_s
          descendant_queries << sql if sql.include?("creative_hierarchies") && sql.include?("ancestor_id")
        end

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          ChangeSetDiff.new(@change_set, user: @user).groups
        end

        bulk_queries = descendant_queries.select { |sql| sql.match?(/ancestor_id.*IN/i) }
        assert_equal 1, bulk_queries.size, descendant_queries.join("\n")
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

      test "does not expose a deleted existing draft target through its former parent" do
        reader = users(:two)
        root_share = CreativeShare.create!(
          creative: @root, user: reader, shared_by: @user, permission: :read
        )
        deny = CreativeShare.create!(
          creative: @child, user: reader, shared_by: @user, permission: :no_access
        )
        PermissionCacheBuilder.propagate_share(root_share)
        PermissionCacheBuilder.propagate_share(deny)
        @change_set.update!(status: "draft", user: users(:ai_bot), actor_kind: "agent", origin: "tool")
        change = @change_set.creative_changes.sole
        change.update!(previous_parent_id: @root.id)
        @child.destroy!

        diff = ChangeSetDiff.new(@change_set, user: reader)

        assert_empty diff.groups
        assert_equal 0, diff.change_count
      end

      test "redacts the former side after private content moves into a readable tree" do
        reader = users(:two)
        public_root = Creative.create!(description: "Public", user: @user)
        public_share = CreativeShare.create!(
          creative: public_root, user: reader, shared_by: @user, permission: :read
        )
        PermissionCacheBuilder.propagate_share(public_share)
        moved = Creative.create!(description: "Private secret", user: @user, parent: @root)
        change_set = nil
        History.track(actor: @user, origin: :editor, anchor: moved) do
          moved.update!(parent: public_root, description: "Public replacement")
          change_set = Current.change_set
        end
        PermissionCacheBuilder.rebuild_for_creative(moved)

        reader_diff = ChangeSetDiff.new(change_set, user: reader)
        rendered = reader_diff.groups.to_json

        assert_includes rendered, I18n.t("collavre.creative_history.snapshot_hidden")
        assert_includes rendered, "Public replacement"
        assert_not_includes rendered, "Private secret"
        assert_not reader_diff.fully_visible?

        owner_diff = ChangeSetDiff.new(change_set, user: @user)
        assert_includes owner_diff.groups.to_json, "Private secret"
        assert owner_diff.fully_visible?
      end

      test "redacts content history that predates a later move into a readable tree" do
        reader = users(:two)
        moved = Creative.create!(description: "Initial private", user: @user, parent: @root)
        private_edit = nil
        History.track(actor: @user, origin: :editor, anchor: moved) do
          moved.update!(description: "Edited private secret")
          private_edit = Current.change_set
        end
        public_root = Creative.create!(description: "Public", user: @user)
        public_share = CreativeShare.create!(
          creative: public_root, user: reader, shared_by: @user, permission: :read
        )
        PermissionCacheBuilder.propagate_share(public_share)
        History.track(actor: @user, origin: :editor, anchor: moved) do
          moved.update!(parent: public_root, description: "Public replacement")
        end
        PermissionCacheBuilder.rebuild_for_creative(moved)

        reader_diff = ChangeSetDiff.new(private_edit, user: reader)
        rendered = reader_diff.groups.to_json

        assert_includes rendered, I18n.t("collavre.creative_history.snapshot_hidden")
        assert_not_includes rendered, "Initial private"
        assert_not_includes rendered, "Edited private secret"
        assert_not reader_diff.fully_visible?

        owner_diff = ChangeSetDiff.new(private_edit, user: @user)
        assert_includes owner_diff.groups.to_json, "Initial private"
        assert_includes owner_diff.groups.to_json, "Edited private secret"
      end

      test "shows recorded history to a reader who can still read its historical boundary" do
        reader = users(:two)
        share = CreativeShare.create!(
          creative: @root, user: reader, shared_by: @user, permission: :read
        )
        PermissionCacheBuilder.propagate_share(share)
        change_set = nil
        History.track(actor: @user, origin: :editor, anchor: @child) do
          @child.update!(description: "Shared update")
          change_set = Current.change_set
        end

        diff = ChangeSetDiff.new(change_set, user: reader)
        group = diff.groups.sole

        assert_includes group.fetch(:before), "New &lt;value&gt;"
        assert_includes group.fetch(:after), "Shared update"
        assert diff.fully_visible?
      end

      test "requires the historical placement path for a moved linked shell" do
        reader = users(:two)
        origin = Creative.create!(description: "Readable origin", user: @user)
        origin_share = CreativeShare.create!(
          creative: origin, user: reader, shared_by: @user, permission: :read
        )
        private_parent = Creative.create!(description: "Private placement", user: @user)
        public_parent = Creative.create!(description: "Public placement", user: @user)
        placement_share = CreativeShare.create!(
          creative: public_parent, user: reader, shared_by: @user, permission: :read
        )
        PermissionCacheBuilder.propagate_share(origin_share)
        PermissionCacheBuilder.propagate_share(placement_share)
        linked = Creative.create!(origin: origin, user: @user, parent: private_parent)
        change_set = nil
        History.track(actor: @user, origin: :editor, anchor: linked) do
          linked.update!(parent: public_parent)
          change_set = Current.change_set
        end
        PermissionCacheBuilder.rebuild_for_creative(linked)

        diff = ChangeSetDiff.new(change_set, user: reader)
        group = diff.groups.sole

        assert_equal I18n.t("collavre.creative_history.snapshot_hidden"), group.fetch(:before)
        assert_not_equal I18n.t("collavre.creative_history.snapshot_hidden"), group.fetch(:after)
        assert_not diff.fully_visible?
      end
    end
  end
end
