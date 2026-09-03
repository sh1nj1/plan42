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
    end
  end
end
