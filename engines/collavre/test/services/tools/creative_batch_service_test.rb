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

      test "does not use the opaque pre-execution approval gate" do
        assert_not CreativeBatchService.requires_approval?
      end

      test "stores an agent batch as a draft under the inherited review policy" do
        task, agent = review_agent_turn
        initial_count = Creative.count

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "create", "parent_id" => @root.id, "description" => "Review me" },
            { "action" => "update", "id" => @root.id, "description" => "Reviewed root" }
          ])
        end

        assert result[:pending_review]
        assert_equal initial_count, Creative.count
        assert_equal "<p>Root</p>", @root.reload.description
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal "draft", draft.status
        assert_equal task.id, draft.task_id
        assert draft.creative_changes.where("creative_id < 0").exists?
      end

      test "keeps auto policy agent batches immediate" do
        task, agent = agent_turn

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "create", "parent_id" => @root.id, "description" => "Immediate" }
          ])
        end

        assert result[:success]
        assert_not result[:pending_review]
        assert @root.children.where("description LIKE ?", "%Immediate%").exists?
      end

      test "stores a taskless MCP write as a draft under review policy" do
        @root.update!(data: @root.data.merge("ai_write_policy" => "review"))

        result = Current.set(user: @user, mcp_request: true) do
          CreativeBatchService.new.call(operations: [
            { "action" => "update", "id" => @root.id, "description" => "MCP proposal" }
          ])
        end

        assert result[:pending_review]
        refute_includes @root.reload.description, "MCP proposal"
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal "mcp", draft.origin
        assert_equal @root.id, draft.anchor_creative_id
        assert_equal "explicit", draft.anchor_source
      end

      test "reviews an archive when a descendant locally requires review" do
        task, agent = agent_turn
        parent = Creative.create!(
          description: "Auto parent", user: @user, parent: @root,
          data: { "ai_write_policy" => "auto" }
        )
        child = Creative.create!(
          description: "Protected child", user: @user, parent: parent,
          data: { "ai_write_policy" => "review" }
        )

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => parent.id } ])
        end

        assert result[:pending_review]
        assert_not parent.reload.archived?
        assert_not child.reload.archived?
      end

      test "keeps a parentless create on the default auto policy" do
        task, agent = review_agent_turn

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "create", "description" => "Independent root" }
          ])
        end

        assert result[:success]
        assert_not result[:pending_review]
        assert Creative.where(parent_id: nil).where("description LIKE ?", "%Independent root%").exists?
      end

      test "approves a parentless create captured with a review-policy batch" do
        task, agent = review_agent_turn

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "create", "parent_id" => @root.id, "description" => "Reviewed child" },
            { "action" => "create", "description" => "Reviewed root" }
          ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])
        root_change = draft.creative_changes.find { |change| change.after["parent_id"].nil? }

        assert_equal @root.id, root_change.previous_parent_id
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :applied, applied.status, applied.skipped.inspect
        assert @root.children.where("description LIKE ?", "%Reviewed child%").exists?
        reviewed_root = Creative.roots.where("description LIKE ?", "%Reviewed root%").sole
        assert_equal agent, reviewed_root.user
      end

      test "returns the existing pending draft for another write in the same turn" do
        task, agent = review_agent_turn

        results = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          first = CreativeBatchService.new.call(operations: [
            { "action" => "update", "id" => @root.id, "description" => "First" }
          ])
          second = CreativeBatchService.new.call(operations: [
            { "action" => "update", "id" => @root.id, "description" => "Second" }
          ])
          [ first, second ]
        end

        assert_equal results.first[:change_set_id], results.second[:change_set_id]
        assert_equal 1, CreativeChangeSet.where(task_id: task.id, status: "draft").count
        assert_equal "<p>Root</p>", @root.reload.description
      end

      test "retains a newly uploaded draft image and applies it without re-uploading" do
        task, agent = review_agent_turn
        data_uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "create", "parent_id" => @root.id, "description" => "![pixel](#{data_uri})" }
          ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])
        change = draft.creative_changes.find_by!(operation: "create")
        signed_id = Creatives::History.extract_signed_ids(change.after["markdown_source"]).find do |candidate|
          ActiveStorage::Blob.find_signed(candidate)
        end
        retained_blob = ActiveStorage::Blob.find_signed!(signed_id)

        assert_equal 1, change.history_file_attachments.count
        assert_no_difference("ActiveStorage::Blob.count") do
          applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
          assert_equal :applied, applied.status, applied.skipped.inspect
        end
        created = @root.children.where("description LIKE ?", "%pixel%").sole
        assert_includes created.data["markdown_source"], signed_id
        assert_equal retained_blob.id, created.files.blobs.sole.id
      end

      test "approves a draft update using its canonical markdown snapshot" do
        @root.update!(
          data: @root.data.merge(
            "ai_write_policy" => "review",
            "content_type" => "markdown",
            "markdown_source" => "Original"
          )
        )
        task, agent = agent_turn
        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "update", "id" => @root.id, "description" => "**Approved**" }
          ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])

        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call

        assert_equal :applied, applied.status
        assert_equal "**Approved**", @root.reload.data["markdown_source"]
        assert_includes @root.description, "<strong>Approved</strong>"
      end

      test "draft approval applies the propagated linked archive family" do
        child, linked = create_private_linked_pair
        task, agent = review_agent_turn

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])

        assert_not child.reload.archived?
        assert_not linked.reload.archived?
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :applied, applied.status
        assert child.reload.archived?
        assert linked.reload.archived?
        assert_equal "applied", draft.reload.status
      end

      test "draft approval applies linked parent progress rollups" do
        child, linked = create_private_linked_pair(progress: 0)
        task, agent = review_agent_turn
        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "update", "id" => child.id, "progress" => 1.0 }
          ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])

        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call

        assert_equal :applied, applied.status, applied.skipped.inspect
        assert_equal 1.0, child.reload.progress
        assert_in_delta 0.5, linked.parent.reload.progress, 0.01
        assert_equal "applied", draft.reload.status
      end

      test "skipping a progress conflict also skips linked parent rollups" do
        child, linked = create_private_linked_pair(progress: 0)
        task, agent = review_agent_turn
        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [
            { "action" => "update", "id" => child.id, "progress" => 1.0 }
          ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])
        child.update!(description: "Later human edit")

        applied = Creatives::ChangeSetApplyService.new(
          source: draft, user: @user, mode: :draft, resolutions: { child.id => "skip" }
        ).call

        assert_equal :rejected, applied.status
        assert_equal "rejected", draft.reload.status
        assert_equal 0.0, child.reload.progress
        assert_in_delta 0.0, linked.parent.reload.progress, 0.01
      end

      test "skipping an archive conflict also skips its propagated family" do
        child, linked = create_private_linked_pair
        task, agent = review_agent_turn
        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])
        expected_root_progress = @root.reload.progress
        expected_foreign_progress = linked.parent.reload.progress
        child.update!(description: "Later human edit")

        applied = Creatives::ChangeSetApplyService.new(
          source: draft, user: @user, mode: :draft, resolutions: { child.id => "skip" }
        ).call

        assert_equal :rejected, applied.status
        assert_equal "rejected", draft.reload.status
        assert_not child.reload.archived?
        assert_not linked.reload.archived?
        assert_includes child.description, "Later human edit"
        assert_in_delta expected_root_progress, @root.reload.progress, 0.01
        assert_in_delta expected_foreign_progress, linked.parent.reload.progress, 0.01
        assert_operator draft.creative_changes.count, :>, 1
      end

      test "skipping a linked archive conflict also skips its origin family" do
        child = Creative.create!(description: "Source", user: @user, parent: @root)
        linked_parent = Creative.create!(description: "Placement", user: @user)
        linked = Creative.create!(origin: child, user: @user, parent: linked_parent)
        task, agent = review_agent_turn
        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => linked.id } ])
        end
        draft = CreativeChangeSet.find(result[:change_set_id])
        linked.update!(sequence: linked.sequence + 1)
        linked_change = draft.creative_changes.find_by!(creative_id: linked.id)
        assert_not_equal linked_change.before, Creatives::History.snapshot(linked)

        applied = Creatives::ChangeSetApplyService.new(
          source: draft, user: @user, mode: :draft, resolutions: { linked.id => "skip" }
        ).call

        assert_equal :rejected, applied.status
        assert_equal "rejected", draft.reload.status
        assert_not child.reload.archived?
        assert_not linked.reload.archived?
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

      test "undo restores a linked placement the actor can read but not write" do
        child, linked = create_private_linked_pair
        CreativeSharesCache.create!(creative: linked, user: @user, permission: :read)

        CreativeBatchService.new.call(operations: [ { "action" => "delete", "id" => child.id } ])
        change_set = CreativeChangeSet.newest_first.first
        filter = Creatives::PermissionFilter.new(user: @user)
        assert_includes filter.readable_ids([ linked.id ]), linked.id
        assert_not_includes filter.readable_ids([ linked.id ], min_permission: :write), linked.id

        revert = Creatives::ChangeSetRevertService.new(change_set: change_set, user: @user).call

        assert_equal :applied, revert.status
        assert_not child.reload.archived?
        assert_not linked.reload.archived?
        assert_in_delta 0.5, linked.parent.reload.progress, 0.01
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

      def review_agent_turn
        @root.update!(data: @root.data.merge("ai_write_policy" => "review"))
        agent_turn
      end

      def agent_turn
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @root, user: agent, shared_by: @user, permission: :write)
        topic = Topic.create!(creative: @root, user: @user, name: "Review #{SecureRandom.hex(3)}")
        task = Task.create!(agent: agent, creative: @root, topic_id: topic.id, name: "Review", status: "running")
        [ task, agent ]
      end

      def create_private_linked_pair(progress: 1)
        child = Creative.create!(description: "<p>Shared source</p>", user: @user, parent: @root, progress: progress)
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
