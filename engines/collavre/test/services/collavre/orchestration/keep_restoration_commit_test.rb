# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class KeepRestorationCommitTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @initial_topic_ids = Topic.ids
        @creative = Creative.create!(description: "Committed keep", user: users(:one))
        @agent = users(:ai_bot)
        @topic = @creative.main_topic
        CreativeShare.find_or_create_by!(creative: @creative, user: @agent).update!(permission: :feedback)
        CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
        ResourceTracker.for(@agent).reset!
        anchor = @creative.comments.create!(content: "Covering", user: users(:one), topic: @topic, skip_dispatch: true)
        @turn = @creative.comments.create!(content: "@#{@agent.name}: Continue", user: users(:one), topic: @topic, skip_dispatch: true)
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: @turn.id, start_comment_id: @turn.id)
        @creative.update!(data: { "trigger" => { "loop" => config } })
        @task = Task.create!(name: "Covering task", agent: @agent, creative: @creative, topic_id: @topic.id,
          status: "running", trigger_event_name: "comment_created", trigger_event_payload: anchor.dispatch_payload.deep_stringify_keys)
        assert DeliveryRecord.claim_drop!(@task, @turn.id, context: @turn.reload.dispatch_payload.deep_stringify_keys)
        @task.update_columns(status: "failed")
        clear_enqueued_jobs
      end

      teardown do
        Topic.where.not(id: @initial_topic_ids).destroy_all if @initial_topic_ids
        @creative&.destroy! if @creative&.persisted?
        ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
      end

      test "a separate worker connection sees the restore claim before publication" do
        published = false
        AiAgentJob.stub(:perform_later, ->(*) {
          ids = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              DeliveryRecord.restored_ids_in(Task.find(@task.id).trigger_event_payload)
            end
          end.value
          assert_includes ids, @turn.id
          published = true
          true
        }) { DeliveryRecord.restore!(@task) }
        assert published
      end

      test "delayed publication commits its claim before scheduling" do
        decision = { timing: :delayed, delay: 30.seconds }
        enqueued = []
        DeliveryRecord.stub(:admitted_restore_decision, decision) do
          AiAgentJob.stub(:set, ->(**options) {
            assert_equal 30.seconds, options[:wait]
            AiAgentJob
          }) do
            AiAgentJob.stub(:perform_later, ->(*args) { enqueued << args; true }) { DeliveryRecord.restore!(@task) }
          end
        end
        assert_equal 1, enqueued.length
        assert_includes DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload), @turn.id
      end

      test "an outer rollback removes the claim and never publishes" do
        AiAgentJob.stub(:perform_later, ->(*) { flunk "Rolled-back claim became a job" }) do
          Task.transaction do
            DeliveryRecord.restore!(@task)
            assert_includes DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload), @turn.id
            raise ActiveRecord::Rollback
          end
        end
        assert_empty DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
      end

      test "pause between claim commit and publication retires the obsolete restore" do
        callbacks = []
        ActiveRecord.stub(:after_all_transactions_commit, ->(&callback) { callbacks << callback }) { DeliveryRecord.restore!(@task) }
        assert callbacks.any?
        @creative.update!(data: @creative.reload.data.deep_merge("trigger" => { "loop" => { "state" => "paused", "generation" => 2 } }))
        before = @creative.reload.data.deep_dup
        AiAgentJob.stub(:perform_later, ->(*) { flunk "Paused restore became a job" }) { callbacks.each(&:call) }
        assert_equal before, @creative.reload.data
        assert_empty DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
        assert_includes DeliveryRecord.rejected_restore_ids_in(@task.trigger_event_payload), @turn.id
      end

      test "post-commit enqueue refusal releases the claim and current keep ownership" do
        AiAgentJob.stub(:perform_later, false) { DeliveryRecord.restore!(@task) }
        assert_empty DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
        assert_includes DeliveryRecord.rejected_restore_ids_in(@task.trigger_event_payload), @turn.id
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "post-commit provider queue exceptions remain retryable without stranding a claim" do
        AiAgentJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) { DeliveryRecord.restore!(@task) }
        assert_empty DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
        assert_empty DeliveryRecord.rejected_restore_ids_in(@task.trigger_event_payload)
      end
    end
  end
end
