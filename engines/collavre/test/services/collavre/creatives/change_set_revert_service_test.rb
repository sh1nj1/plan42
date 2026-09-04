# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class ChangeSetRevertServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @root = Creative.create!(description: "Root", user: @user)
        @child = Creative.create!(description: "Before", user: @user, parent: @root)
        @change_set = recorded_update
        Current.reset
      end

      test "applies the inverse as a linked append-only change set" do
        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :applied, result.status
        assert_equal "Before", @child.reload.description
        assert_equal "reverted", @change_set.reload.status
        assert_equal result.change_set, @change_set.reverted_by
        assert_equal @change_set, result.change_set.reverts
        assert_equal "revert", result.change_set.origin
        assert_equal "After", result.change_set.creative_changes.sole.before.fetch("description")
        assert_equal "Before", result.change_set.creative_changes.sole.after.fetch("description")
      end

      test "reports a conflict without changing the Creative" do
        @child.update!(description: "Human follow-up")

        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :conflict, result.status
        assert_equal [ @child.id ], result.conflicts.pluck(:creative_id)
        assert_equal "Human follow-up", @child.reload.description
        assert_equal "applied", @change_set.reload.status
      end

      test "supports force and skip resolutions per Creative" do
        @child.update!(description: "Human follow-up")
        skipped = ChangeSetRevertService.new(
          change_set: @change_set,
          user: @user,
          resolutions: { @child.id => "skip" }
        ).call
        assert_equal :skipped, skipped.status
        assert_equal [ @child.id ], skipped.skipped

        forced = ChangeSetRevertService.new(
          change_set: @change_set,
          user: @user,
          resolutions: { @child.id => "force" }
        ).call
        assert_equal :applied, forced.status
        assert_equal "Before", @child.reload.description
      end

      test "skips unreadable Creatives without exposing their ids" do
        result = ChangeSetRevertService.new(change_set: @change_set, user: users(:two)).call

        assert_equal :skipped, result.status
        assert_empty result.skipped
        assert_equal "After", @child.reload.description
      end

      test "does not move a Creative under a parent the user cannot write" do
        foreign_parent = Creative.create!(description: "Private", user: users(:two))
        change = @change_set.creative_changes.sole
        change.update!(before: change.before.merge("parent_id" => foreign_parent.id))

        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :skipped, result.status
        assert_equal [ @child.id ], result.skipped
        assert_equal @root, @child.reload.parent
      end

      test "does not move a Creative under a read only parent" do
        read_only_parent = Creative.create!(
          description: "Synced",
          user: @user,
          data: { "source" => { "type" => "github_markdown" } }
        )
        change = @change_set.creative_changes.sole
        change.update!(before: change.before.merge("parent_id" => read_only_parent.id))

        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :skipped, result.status
        assert_equal [ @child.id ], result.skipped
        assert_equal @root, @child.reload.parent
      end

      test "does not restore a move that would create a hierarchy cycle" do
        destination = Creative.create!(description: "Destination", user: @user)
        moved = nil
        History.track(actor: @user, origin: :editor, anchor: @root) do
          @child.update!(parent: destination)
          moved = Current.change_set
        end
        Current.reset
        @root.update!(parent: @child)

        result = ChangeSetRevertService.new(change_set: moved, user: @user).call

        assert_equal :skipped, result.status
        assert_equal [ @child.id ], result.skipped
        assert_equal destination, @child.reload.parent
        assert_equal @child, @root.reload.parent
      end

      test "skips a Creative that became read only after the recorded edit" do
        data = @child.data.deep_dup
        data["source"] = { "type" => "github_markdown" }
        @child.update_column(:data, data)

        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :skipped, result.status
        assert_equal [ @child.id ], result.skipped
        assert_equal "After", @child.reload.description
      end

      test "loads merged targets while holding the source lock" do
        sibling = Creative.create!(description: "Sibling after", user: @user, parent: @root)
        source = @change_set
        lock_relation = Object.new
        lock_relation.define_singleton_method(:find) do |id|
          source.creative_changes.create!(
            creative: sibling,
            operation: "update",
            before: History.snapshot(sibling).merge("description" => "Sibling before"),
            after: History.snapshot(sibling),
            position: 1
          )
          CreativeChangeSet.find(id)
        end

        result = CreativeChangeSet.stub(:lock, lock_relation) do
          ChangeSetRevertService.new(change_set: @change_set, user: @user).call
        end

        assert_equal :applied, result.status
        assert_equal "Before", @child.reload.description
        assert_equal "Sibling before", sibling.reload.description
        assert_equal "reverted", @change_set.reload.status
      end

      test "keeps a partial revert retryable and skips already reverted Creatives" do
        foreign = Creative.create!(description: "Foreign after", user: users(:two))
        perform_enqueued_jobs do
          CreativeShare.create!(creative: foreign, user: @user, shared_by: users(:two), permission: :read)
        end
        @change_set.creative_changes.create!(
          creative: foreign,
          operation: "update",
          before: History.snapshot(foreign).merge("description" => "Foreign before"),
          after: History.snapshot(foreign),
          position: 1
        )

        partial = ChangeSetRevertService.new(change_set: @change_set, user: @user).call
        assert_equal :partial, partial.status
        assert_equal [ foreign.id ], partial.skipped
        assert_equal "Before", @child.reload.description
        assert_equal "applied", @change_set.reload.status

        perform_enqueued_jobs do
          CreativeShare.find_by!(creative: foreign, user: @user).update!(permission: :write)
        end
        retried = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :applied, retried.status
        assert_equal "Foreign before", foreign.reload.description
        assert_equal "Before", @child.reload.description
        assert_equal "reverted", @change_set.reload.status
        assert_equal [ foreign.id ], retried.change_set.creative_changes.pluck(:creative_id)
      end

      test "does not expose or mark unreadable changes as reverted" do
        foreign = Creative.create!(description: "Foreign after", user: users(:two))
        @change_set.update!(summary: "Foreign secret summary")
        @change_set.creative_changes.create!(
          creative: foreign,
          operation: "update",
          before: History.snapshot(foreign).merge("description" => "Foreign before"),
          after: History.snapshot(foreign),
          position: 1
        )

        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :partial, result.status
        assert_empty result.skipped
        assert_equal "Foreign after", foreign.reload.description
        assert_equal "applied", @change_set.reload.status
        assert_nil result.change_set.summary
      end

      test "does not revert synchronized or already reverted sets" do
        @change_set.update!(origin: "sync")
        assert_equal :not_revertible,
                     ChangeSetRevertService.new(change_set: @change_set, user: @user).call.status

        @change_set.update!(origin: "editor", status: "reverted")
        assert_equal :not_revertible,
                     ChangeSetRevertService.new(change_set: @change_set, user: @user).call.status
      end

      test "does not offer a lossy reconstruction for hard-deleted Creatives" do
        change = @change_set.creative_changes.sole
        change.update!(operation: "destroy", after: {})
        @child.destroy!

        assert_equal :not_revertible,
                     ChangeSetRevertService.new(change_set: @change_set, user: @user).call.status
      end

      test "archives a Creative when reverting its creation" do
        created = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          created = Creative.create!(description: "Created", user: @user, parent: @root)
          creation = Current.change_set
        end
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :applied, result.status
        assert created.reload.archived?
      end

      test "reports a conflict when a created Creative gained a later child" do
        created, creation = recorded_creation
        later_child = Creative.create!(description: "Later child", user: @user, parent: created)
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :conflict, result.status
        assert_equal [ created.id ], result.conflicts.pluck(:creative_id)
        assert_not created.reload.archived?
        assert_not later_child.reload.archived?
      end

      test "force archives a created Creative and its later subtree" do
        created, creation = recorded_creation
        later_child = Creative.create!(description: "Later child", user: @user, parent: created)
        Current.reset

        result = ChangeSetRevertService.new(
          change_set: creation, user: @user, resolutions: { created.id => "force" }
        ).call

        assert_equal :applied, result.status
        assert created.reload.archived?
        assert later_child.reload.archived?
        assert_equal [ created.id, later_child.id ].sort,
                     result.change_set.creative_changes.pluck(:creative_id).sort
      end

      test "reverts Creatives created together without treating their hierarchy as later" do
        created_parent = nil
        created_child = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          created_parent = Creative.create!(description: "Created parent", user: @user, parent: @root)
          created_child = Creative.create!(description: "Created child", user: @user, parent: created_parent)
          creation = Current.change_set
        end
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :applied, result.status
        assert created_parent.reload.archived?
        assert created_child.reload.archived?
      end

      test "reverting creation of a linked shell does not archive its existing origin" do
        linked = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          linked = Creative.create!(user: @user, origin: @child)
          creation = Current.change_set
        end
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :applied, result.status
        assert linked.reload.archived?
        assert_not @child.reload.archived?
      end

      test "reverting a linked shell keeps children normalized onto its existing origin" do
        linked = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          linked = Creative.create!(user: @user, origin: @child)
          creation = Current.change_set
        end
        Current.reset
        later_child = Creative.create!(description: "Later child", user: @user, parent: linked)
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :applied, result.status
        assert linked.reload.archived?
        assert_equal @child.id, later_child.reload.parent_id
        assert_not later_child.archived?
        assert_not @child.reload.archived?
      end

      test "restores a selected version without marking its source reverted" do
        @child.update!(description: "Newest")

        result = ChangeSetRestoreService.new(change_set: @change_set, user: @user).call

        assert_equal :applied, result.status
        assert_equal "After", @child.reload.description
        assert_equal "applied", @change_set.reload.status
        assert_nil result.change_set.reverts

        reverted = ChangeSetRevertService.new(change_set: @change_set, user: @user).call
        assert_equal :applied, reverted.status
        assert_equal "Before", @child.reload.description
      end

      private

      def recorded_creation
        created = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          created = Creative.create!(description: "Created", user: @user, parent: @root)
          creation = Current.change_set
        end
        Current.reset
        [ created, creation ]
      end

      def recorded_update
        change_set = nil
        History.track(actor: @user, origin: :editor, anchor: @root, anchor_source: :view_root) do
          @child.update!(description: "After")
          change_set = Current.change_set
        end
        change_set
      end
    end
  end
end
