# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeBatchServiceTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Batch Test", email: "batch_test_#{SecureRandom.hex(4)}@example.com", password: "password123")
        Current.user = @user
        @root = Creative.create!(description: "<p>Root</p>", user: @user, progress: 0)
        # Ensure permission cache is populated for the owner
        CreativeSharesCache.find_or_create_by!(creative: @root, user: @user) do |cache|
          cache.permission = :admin
        end
      end

      teardown do
        Current.user = nil
      end

      test "requires_approval? returns true" do
        assert CreativeBatchService.requires_approval?
      end

      test "creates a creative via batch" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "create", "parent_id" => @root.id, "description" => "Batch created task" }
        ])

        assert result[:success]
        assert_equal 1, result[:results].size
        assert result[:results][0][:id].present?
      end

      test "updates a creative via batch" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "update", "id" => @root.id, "progress" => 1.0 }
        ])

        assert result[:success]
        assert_equal 1.0, result[:results][0][:progress]
      end

      test "archives a creative subtree via batch" do
        child = Creative.create!(description: "<p>To archive</p>", user: @user, parent: @root)
        grandchild = Creative.create!(description: "<p>Nested</p>", user: @user, parent: child)
        Current.change_set = nil

        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "delete", "id" => child.id }
        ])

        assert result[:success]
        assert result[:results][0][:archived]
        assert child.reload.archived?
        assert grandchild.reload.archived?
        change_set = CreativeChangeSet.newest_first.first
        assert_equal %w[archive archive], change_set.creative_changes.order(:creative_id).pluck(:operation)

        revert = Creatives::ChangeSetRevertService.new(change_set: change_set, user: @user).call
        assert_equal :applied, revert.status
        assert_not child.reload.archived?
        assert_not grandchild.reload.archived?
      end

      test "undo restores linked shells propagated into a private tree" do
        child, linked = create_private_linked_pair

        result = CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        change_set = CreativeChangeSet.newest_first.first

        assert result[:success]
        assert linked.reload.archived?
        assert_in_delta 0, linked.parent.reload.progress, 0.01
        assert_not_includes Creatives::PermissionFilter.new(user: @user).readable_ids([ linked.id ]), linked.id

        revert = Creatives::ChangeSetRevertService.new(change_set: change_set, user: @user).call

        assert_equal :applied, revert.status
        assert_equal "reverted", change_set.reload.status
        assert_not child.reload.archived?
        assert_not linked.reload.archived?
        assert_in_delta 0.5, linked.parent.reload.progress, 0.01
        assert_includes revert.change_set.creative_changes.pluck(:creative_id), linked.id

        restore = Creatives::ChangeSetRestoreService.new(change_set: change_set, user: @user).call

        assert_equal :applied, restore.status
        assert child.reload.archived?
        assert linked.reload.archived?
      end

      test "undo treats an independently restored hidden shell as complete" do
        child, linked = create_private_linked_pair

        CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        change_set = CreativeChangeSet.newest_first.first
        linked.update_column(:archived_at, nil)

        revert = Creatives::ChangeSetRevertService.new(change_set: change_set, user: @user).call

        assert_equal :applied, revert.status
        assert_equal "reverted", change_set.reload.status
        assert_not child.reload.archived?
        assert_not linked.reload.archived?
      end

      test "undo succeeds when the entire propagated family was already restored" do
        child, linked = create_private_linked_pair

        CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        change_set = CreativeChangeSet.newest_first.first
        Current.change_set = nil
        child.unarchive!

        revert = Creatives::ChangeSetRevertService.new(change_set: change_set, user: @user).call

        assert_equal :applied, revert.status
        assert_nil revert.change_set
        assert_equal "reverted", change_set.reload.status
        assert_not child.reload.archived?
        assert_not linked.reload.archived?
      end

      test "undo does not overwrite or expose an independently rearchived hidden shell" do
        child, linked = create_private_linked_pair

        CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        change_set = CreativeChangeSet.newest_first.first
        later_archive = 1.hour.from_now
        linked.update_column(:archived_at, later_archive)

        revert = Creatives::ChangeSetRevertService.new(change_set: change_set, user: @user).call

        assert_equal :partial, revert.status
        assert_equal "applied", change_set.reload.status
        assert_not child.reload.archived?
        assert_in_delta later_archive, linked.reload.archived_at, 0.001
        assert_not_includes revert.skipped, linked.id
      end

      test "mixed operations in a single batch" do
        child = Creative.create!(description: "<p>Child</p>", user: @user, parent: @root)
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "create", "parent_id" => @root.id, "description" => "New task" },
          { "action" => "update", "id" => child.id, "description" => "<p>Updated child</p>" }
        ])

        assert result[:success]
        assert_equal 2, result[:results].size
      end

      test "unknown action returns error" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "unknown_action" }
        ])

        assert_not result[:success]
        assert_match(/Unknown action/, result[:error])
      end

      test "moving a creative in a batch enqueues the subtree touch" do
        moved = Creative.create!(description: "<p>Moved</p>", user: @user, progress: 0)
        Creative.create!(description: "<p>Descendant</p>", user: @user, parent: moved, progress: 0)
        CreativeSharesCache.find_or_create_by!(creative: moved, user: @user) { |cache| cache.permission = :admin }

        service = CreativeBatchService.new
        original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test

        # The batch wraps every operation in one transaction, and the update
        # service saves parent_id, saves again for the description, then
        # reloads — all of which erase the parent change from saved_changes
        # before after_commit runs.
        assert_enqueued_with(job: TouchCreativeSubtreeJob, args: [ moved.id ]) do
          result = service.call(operations: [
            { "action" => "update", "id" => moved.id, "parent_id" => @root.id, "description" => "Moved and renamed" }
          ])

          assert result[:success], result[:error]
        end
      ensure
        ActiveJob::Base.queue_adapter = original_adapter if original_adapter
      end

      test "rename then move of the same creative enqueues one subtree touch" do
        moved = Creative.create!(description: "<p>Moved</p>", user: @user, progress: 0)
        Creative.create!(description: "<p>Descendant</p>", user: @user, parent: moved, progress: 0)
        CreativeSharesCache.find_or_create_by!(creative: moved, user: @user) { |cache| cache.permission = :admin }

        service = CreativeBatchService.new
        original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test

        Creative.stub :run_commit_callbacks_on_first_saved_instances_in_transaction, true do
          assert_enqueued_jobs 1, only: TouchCreativeSubtreeJob do
            result = service.call(operations: [
              { "action" => "update", "id" => moved.id, "description" => "Renamed" },
              { "action" => "update", "id" => moved.id, "parent_id" => @root.id }
            ])

            assert result[:success], result[:error]
          end
        end
      ensure
        ActiveJob::Base.queue_adapter = original_adapter if original_adapter
      end

      test "rolls back all operations on failure" do
        initial_count = Creative.count

        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "create", "parent_id" => @root.id, "description" => "Should be rolled back" },
          { "action" => "delete", "id" => 999_999 }
        ])

        assert_not result[:success]
        assert_equal initial_count, Creative.count
      end

      private

      def create_private_linked_pair
        child = Creative.create!(description: "<p>Shared source</p>", user: @user, parent: @root, progress: 1)
        foreign_user = users(:two)
        foreign_root = Creative.create!(description: "<p>Private tree</p>", user: foreign_user)
        Creative.create!(description: "<p>Incomplete</p>", user: foreign_user, parent: foreign_root, progress: 0)
        linked = Creative.create!(origin: child, user: foreign_user, parent: foreign_root)
        Current.change_set = nil
        [ child, linked ]
      end
    end
  end
end
