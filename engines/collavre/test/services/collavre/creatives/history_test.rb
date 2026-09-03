# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class HistoryTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      setup do
        @user = users(:one)
        @root = Creative.create!(description: "Root", user: @user)
        @child = Creative.create!(description: "Child", user: @user, parent: @root)
      end

      test "groups repeated writes and keeps the first before and latest after snapshots" do
        History.track(
          actor: @user,
          origin: :editor,
          anchor: @root,
          anchor_source: :view_root,
          change_group_token: "editing-session"
        ) do
          @child.update!(description: "First")
          @child.update!(description: "Second")
        end

        change_set = CreativeChangeSet.sole
        change = change_set.creative_changes.sole

        assert_equal @root.id, change_set.anchor_creative_id
        assert_equal "view_root", change_set.anchor_source
        assert_equal "human", change_set.actor_kind
        assert_equal "editor", change_set.origin
        assert_equal "editing-session", change_set.change_group_token
        assert_equal "Child", change.before.fetch("description")
        assert_equal "Second", change.after.fetch("description")
        assert_equal "update", change.operation
        assert_equal 2, @child.reload.revision
      end

      test "serializes writes against the change set row" do
        change_set = CreativeChangeSet.create!(
          actor_kind: "human",
          origin: "editor",
          status: "applied",
          user: @user,
          applied_at: Time.current
        )
        locked = false
        lock = lambda do |&block|
          locked = true
          block.call
        end
        before = History.snapshot(@child)
        @child.update_column(:description, "Serialized")

        change_set.stub(:with_lock, lock) do
          History.stub(:current_change_set, change_set) do
            History.track(actor: @user, origin: :editor) do
              History.record(@child.reload, operation: :update, before: before, after: History.snapshot(@child))
            end
          end
        end

        assert locked
        assert_equal "Serialized", change_set.creative_changes.sole.after.fetch("description")
      end

      test "stores canonical markdown without its generated HTML" do
        History.track(actor: @user, origin: :editor, anchor: @root) do
          @child.content_type_input = "markdown"
          @child.markdown_source = "# Updated"
          @child.markdown_editor = "rich"
          @child.save!
        end

        after = CreativeChange.sole.after
        assert_equal "# Updated", after.fetch("markdown_source")
        assert_equal "markdown", after.fetch("content_type")
        assert_equal "rich", after.fetch("editor")
        assert_not after.key?("description")
      end

      test "merges human edits with the same token inside the idle window" do
        travel_to Time.zone.local(2026, 9, 3, 10, 0, 0) do
          track_editor_change("same-token") { @child.update!(description: "First") }
          travel 4.minutes
          track_editor_change("same-token") { @child.update!(description: "Second") }
        end

        assert_equal 1, CreativeChangeSet.count
        assert_equal "Child", CreativeChange.sole.before.fetch("description")
        assert_equal "Second", CreativeChange.sole.after.fetch("description")
      end

      test "starts a new human change set after five idle minutes" do
        travel_to Time.zone.local(2026, 9, 3, 10, 0, 0) do
          track_editor_change("same-token") { @child.update!(description: "First") }
          travel 6.minutes
          track_editor_change("same-token") { @child.update!(description: "Second") }
        end

        assert_equal 2, CreativeChangeSet.count
      end

      test "rolls history back with the creative write" do
        Creative.transaction do
          History.track(actor: @user, origin: :editor, anchor: @root) do
            @child.update!(description: "Rolled back")
            raise ActiveRecord::Rollback
          end
        end

        assert_equal "Child", @child.reload.description
        assert_empty CreativeChangeSet.all
      end

      test "recovers implicit turn tracking after a transaction rollback" do
        Current.set(user: @user) do
          Creative.transaction do
            @child.update!(description: "Rolled back")
            raise ActiveRecord::Rollback
          end

          @child.update!(description: "Retried")
        end

        assert_equal "Retried", @child.reload.description
        assert_equal 1, CreativeChangeSet.count
        assert_equal "Child", CreativeChange.sole.before.fetch("description")
        assert_equal "Retried", CreativeChange.sole.after.fetch("description")
      end

      test "increments revisions atomically across stale model instances" do
        first = Creative.find(@child.id)
        second = Creative.find(@child.id)

        track_editor_change("first") { first.update!(description: "First") }
        Current.reset
        track_editor_change("second") { second.update!(description: "Second") }

        assert_equal 2, second.revision
        assert_equal 2, @child.reload.revision
      end

      test "captures the baseline after locking and reloading a stale creative" do
        stale = Creative.find(@child.id)
        @child.update_column(:description, "Concurrent edit")

        track_editor_change("stale") { stale.update!(description: "Final edit") }

        change = CreativeChange.sole
        assert_equal "Concurrent edit", change.before.fetch("description")
        assert_equal "Final edit", change.after.fetch("description")
      end

      test "does not record an unscoped write without a current actor" do
        @child.update!(description: "Background maintenance")

        assert_empty CreativeChangeSet.all
        assert_equal 0, @child.reload.revision
      end

      test "records a create as one change with an empty before snapshot" do
        created = nil
        History.track(actor: @user, origin: :import, anchor: @root, anchor_source: :import_target) do
          created = Creative.create!(description: "Imported", user: @user, parent: @root)
        end

        change = CreativeChange.sole
        assert_equal "create", change.operation
        assert_equal({}, change.before)
        assert_equal "Imported", change.after.fetch("description")
        assert_equal 1, created.reload.revision
      end

      test "records an explicit hard destroy for audit history" do
        child_id = @child.id

        History.track(actor: @user, origin: :editor, anchor: @root) do
          Creatives::DestroyService.new(creative: @child, user: @user, delete_with_children: true).call
        end

        change = CreativeChange.sole
        assert_equal child_id, change.creative_id
        assert_equal "destroy", change.operation
        assert_equal "Child", change.before.fetch("description")
        assert_equal({}, change.after)
      end

      test "keeps bulk snapshots and writes in one transaction" do
        History.track(actor: @user, origin: :editor, anchor: @root) do
          History.record_bulk([ @child ], operation: "reorder") do
            assert Creative.connection.transaction_open?
            @child.update_column(:sequence, 7)
            raise ActiveRecord::Rollback
          end
        end

        assert_not_equal 7, @child.reload.sequence
        assert_empty CreativeChangeSet.all
      end

      test "retains the former parent when an existing change becomes a destroy" do
        History.track(actor: @user, origin: :editor, anchor: @root) do
          @child.update!(description: "Updated before deletion")
          @child.destroy!
        end

        change = CreativeChange.sole
        assert_equal "destroy", change.operation
        assert_equal @root.id, change.previous_parent_id
        assert_equal [ change.change_set ], CreativeChangeSet.for_creative_scope(@root).to_a
      end

      test "retains the former parent when a Creative moves to another tree" do
        destination = Creative.create!(description: "Destination", user: @user)

        History.track(actor: @user, origin: :editor, anchor: @root) do
          @child.update!(parent: destination)
        end

        change = CreativeChange.find_by!(creative_id: @child.id)
        assert_equal "move", change.operation
        assert_equal @root.id, change.previous_parent_id
        assert_includes CreativeChangeSet.for_creative_scope(@root), change.change_set
      end

      test "does not create a History topic when the deleted Creative was its own anchor" do
        root = Creative.create!(description: "Deleted root", user: @user)

        History.track(actor: @user, origin: :editor, anchor: root) { root.destroy! }

        assert_nil Topic.find_by(creative_id: root.id, name: Creative::HISTORY_TOPIC_NAME)
      end

      test "discards a change that returns to its initial state" do
        History.track(actor: @user, origin: :editor, anchor: @root) do
          @child.update!(description: "Temporary")
          @child.update!(description: "Child")
        end

        assert_empty CreativeChangeSet.all
        assert_equal 2, @child.reload.revision
      end

      test "preserves an outer change set through nested tracking" do
        History.track(actor: @user, origin: :tool, anchor: @root) do
          @child.update!(description: "Outer")
          History.track(actor: @user, origin: :import, anchor: @child) do
            @root.update!(description: "Nested")
          end
        end

        assert_equal 1, CreativeChangeSet.count
        assert_equal [ @root.id, @child.id ].sort, CreativeChange.pluck(:creative_id).sort
        assert_equal "tool", CreativeChangeSet.sole.origin
      end

      test "captures agent turn attribution" do
        agent = users(:ai_bot)
        topic = Topic.create!(creative: @root, user: @user, name: "Agent work")
        task = Task.create!(agent: agent, creative: @root, topic_id: topic.id, name: "Edit", status: "running")

        History.track(
          actor: agent,
          origin: :tool,
          anchor: @root,
          anchor_source: :agent_topic,
          task: task,
          topic: topic,
          summary: "Update the child"
        ) { @child.update!(description: "Agent edit") }

        change_set = CreativeChangeSet.sole
        assert_equal "agent", change_set.actor_kind
        assert_equal agent.id, change_set.user_id
        assert_equal task.id, change_set.task_id
        assert_equal topic.id, change_set.topic_id
        assert_equal "Update the child", change_set.summary
        assert change_set.applied_at.present?
      end

      test "implicitly groups all writes in one agent turn" do
        agent = users(:ai_bot)
        sibling = Creative.create!(description: "Sibling", user: @user, parent: @root)
        topic = Topic.create!(creative: @root, user: @user, name: "Agent turn")
        task = Task.create!(agent: agent, creative: @root, topic_id: topic.id, name: "Edit", status: "running")

        Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          @child.update!(description: "First tool write")
          sibling.update!(description: "Second tool write")
        end

        change_set = CreativeChangeSet.sole
        assert_equal task.id, change_set.task_id
        assert_equal topic.id, change_set.topic_id
        assert_equal @root.id, change_set.anchor_creative_id
        assert_equal [ @child.id, sibling.id ].sort, change_set.creative_changes.pluck(:creative_id).sort
      end

      test "keeps nested import tracking in the enclosing agent turn" do
        agent = users(:ai_bot)
        topic = Topic.create!(creative: @root, user: @user, name: "Agent import")
        task = Task.create!(agent: agent, creative: @root, topic_id: topic.id, name: "Import", status: "running")

        Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          History.track(actor: agent, origin: :import, anchor: @child, anchor_source: :import_target) do
            @child.update!(description: "Imported")
          end
          @root.update!(description: "Same turn")
        end

        change_set = CreativeChangeSet.sole
        assert_equal "tool", change_set.origin
        assert_equal task.id, change_set.task_id
        assert_equal topic.id, change_set.topic_id
        assert_equal @root.id, change_set.anchor_creative_id
        assert_equal [ @root.id, @child.id ].sort, change_set.creative_changes.pluck(:creative_id).sort
      end

      test "infers MCP attribution when a write is not explicitly scoped" do
        Current.set(user: @user, mcp_request: true) do
          @child.update!(description: "MCP edit")
        end

        change_set = CreativeChangeSet.sole
        assert_equal "mcp", change_set.origin
        assert_equal @child.id, change_set.anchor_creative_id
        assert_equal "explicit", change_set.anchor_source
      end

      test "hides sync history from the default scope and leaves drafts unapplied" do
        History.track(actor: nil, origin: :sync, anchor: @root, status: "draft") do
          @child.update!(description: "Synced draft")
        end

        change_set = CreativeChangeSet.sole
        assert_equal "sync", change_set.actor_kind
        assert_nil change_set.applied_at
        assert_empty CreativeChangeSet.visible_by_default
      end

      test "records every propagated archive and unarchive" do
        linked = Creative.create!(description: "Linked", user: @user, origin_id: @root.id)

        History.track(actor: @user, origin: :editor, anchor: @root) { @root.archive! }
        archived_set = CreativeChangeSet.sole
        assert_equal [ @root.id, @child.id, linked.id ].sort,
                     archived_set.creative_changes.pluck(:creative_id).sort
        assert archived_set.creative_changes.all? { |change| change.operation == "archive" }
        root_change = archived_set.creative_changes.find_by!(creative_id: @root.id)
        assert_equal History.snapshot(@root.reload), root_change.reload.after

        Current.reset
        History.track(actor: @user, origin: :editor, anchor: @root) { @root.unarchive! }
        restored_set = CreativeChangeSet.newest_first.first
        assert_equal [ @root.id, @child.id, linked.id ].sort,
                     restored_set.creative_changes.pluck(:creative_id).sort
        assert restored_set.creative_changes.all? { |change| change.operation == "unarchive" }
      end

      test "queries change sets touching the viewed subtree newest first" do
        unrelated = Creative.create!(description: "Unrelated", user: @user)
        track_editor_change("root") { @child.update!(description: "Older") }
        travel 1.second
        track_editor_change("root-2") { @root.update!(description: "Newer") }
        track_editor_change("other") { unrelated.update!(description: "Elsewhere") }

        sets = CreativeChangeSet.for_creative_scope(@root).to_a
        assert_equal 2, sets.size
        assert_equal @root.id, sets.first.creative_changes.sole.creative_id
        assert_equal @child.id, sets.second.creative_changes.sole.creative_id
      end

      test "keeps a destroyed subtree discoverable from its surviving parent" do
        grandchild = Creative.create!(description: "Grandchild", user: @user, parent: @child)

        History.track(actor: @user, origin: :editor, anchor: @root) do
          grandchild.destroy!
          @child.destroy!
        end

        change_set = CreativeChangeSet.sole
        assert_equal [ @child.id, grandchild.id ].sort, change_set.creative_changes.pluck(:creative_id).sort
        assert_equal @root.id, change_set.creative_changes.find_by!(creative_id: @child.id).previous_parent_id
        assert_equal [ change_set ], CreativeChangeSet.for_creative_scope(@root).to_a
      end

      test "queries both a linked shell and its effective origin subtree" do
        folder = Creative.create!(description: "Folder", user: @user)
        linked = Creative.create!(user: @user, parent: folder, origin_id: @root.id)
        shell_child = Creative.create!(description: "Shell child", user: @user, parent: linked)

        track_editor_change("origin") { @child.update!(description: "Origin child edit") }
        Current.reset
        track_editor_change("shell") { shell_child.update!(description: "Shell edit") }

        changes = CreativeChangeSet.for_creative_scope(linked).flat_map(&:creative_changes)
        assert_equal [ @child.id, shell_child.id ].sort, changes.map(&:creative_id).sort
      end

      test "validates change set and change vocabularies" do
        change_set = CreativeChangeSet.new(
          actor_kind: "unknown",
          anchor_source: "unknown",
          origin: "unknown",
          status: "unknown"
        )
        assert_not change_set.valid?

        change = CreativeChange.new(operation: "unknown")
        assert_not change.valid?
      end

      private

      def track_editor_change(token, &block)
        History.track(
          actor: @user,
          origin: :editor,
          anchor: @root,
          anchor_source: :view_root,
          change_group_token: token,
          &block
        )
      end
    end
  end
end
