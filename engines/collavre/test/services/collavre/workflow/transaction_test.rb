# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Workflow
    # Real commits: transactional fixtures cannot prove the separate-queue gap.
    class TransactionTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper
      self.use_transactional_tests = false

      setup do
        @initial_topic_ids = Topic.ids
        @adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @owner = users(:one)
        @workflow = create_workflow
        @rule = create_workflow_rule(parent: @workflow, handler: { "type" => "human" })
        @creative = create_workflow_creative(description: "Committed workflow", data: { "context_ids" => [ @workflow.id ] })
        @topic = Topic.create!(creative: @creative, user: @owner, name: "Committed workflow")
        @comment = Comment.create!(creative: @creative, topic: @topic, user: @owner, content: "Committed input", skip_dispatch: true)
        @policy = OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "on" })
        @context = @comment.dispatch_payload.deep_stringify_keys
        @invocation = { source: "drop_trigger", job_id: SecureRandom.uuid }
      end

      teardown do
        deliveries = CommentNotificationDelivery.where.not(workflow_execution_id: nil)
        notice_ids = deliveries.pluck(:inbox_comment_id)
        deliveries.delete_all
        Comment.where(id: notice_ids).destroy_all
        Receipt.delete_all
        workflow_tasks = Task.where.not(workflow_execution_id: nil)
        Comment.where(task_id: workflow_tasks.select(:id)).update_all(task_id: nil)
        TaskAction.where(task_id: workflow_tasks.select(:id)).delete_all
        Task.where.not(workflow_execution_id: nil).delete_all
        Outbox.delete_all
        Execution.delete_all
        Chain.delete_all
        Topic.where.not(id: @initial_topic_ids).destroy_all if @initial_topic_ids
        @creative&.destroy!
        @workflow&.destroy!
        @policy&.destroy!
        ActiveJob::Base.queue_adapter = @adapter
      end

      test "rollback creates no workflow rows or queue effects" do
        before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
        Execution.transaction do
          dispatch
          assert_equal before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
          raise ActiveRecord::Rollback
        end
        assert_empty Execution.all
        assert_empty Receipt.all
        assert_equal before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
      end

      test "committed handoff recovers after the enqueue callback is lost" do
        Recovery.stub(:execution, nil) { dispatch }
        execution = Receipt.first.execution
        delivery = CommentNotificationDelivery.find_by!(workflow_execution_id: execution.id)
        assert_equal "pending", delivery.push_state
        assert_equal "human_handoff", execution.reason
        assert_nil delivery.push_claim_token
        CommentPushDeliverySweepJob.perform_now
        assert_equal "enqueued", delivery.reload.push_state
        assert_equal 1, delivery.push_attempts
        assert_equal 1, Comment.where(notification_key: delivery.delivery_key).count
      end

      test "receipt redelivery inside a rolled-back transaction cannot enqueue" do
        Recovery.stub(:execution, nil) { dispatch }
        before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
        Execution.transaction do
          assert dispatch.workflow_handled?
          assert_equal before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
          raise ActiveRecord::Rollback
        end
        assert_equal before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
        assert_nil CommentNotificationDelivery.where.not(workflow_execution_id: nil).first.push_claim_token
      end

      test "committed envelope recovery waits for outer commit and survives rollback" do
        context = @context.merge("event_name" => "comment_created",
          "event" => SystemEvents::Envelope.root("comment_created", source: "comment_callback").to_h)
        outcome = Recovery.stub(:execution, nil) do
          SystemEvents::Dispatcher.dispatch_with_outcome("comment_created", context, source: "comment_callback")
        end
        execution = Execution.find(outcome.workflow_execution_id)
        delivery = CommentNotificationDelivery.find_by!(workflow_execution_id: execution.id)
        assert_equal "pending", delivery.push_state
        recoveries = []
        Recovery.stub(:execution, ->(row) { recoveries << row.id }) do
          Execution.transaction do
            assert_equal execution.id, Recovery.dispatch(context).workflow_execution_id
            assert_empty recoveries
            raise ActiveRecord::Rollback
          end
          assert_empty recoveries
          Execution.transaction do
            assert_equal execution.id, Recovery.dispatch(context).workflow_execution_id
            assert_empty recoveries
          end
          assert_equal [ execution.id ], recoveries
        end
        @rule.update!(archived_at: Time.current)
        Orchestration::Selection.stub(:new, ->(*) { flunk "must recover committed outcome" }) do
          assert_equal execution.id, SystemEvents::Dispatcher.dispatch_with_outcome(
            "comment_created", context, source: "comment_callback").workflow_execution_id
        end
        assert_equal "suppressed", delivery.reload.push_state
        assert_equal "human_handoff", execution.reload.reason
        assert_empty Receipt.all
      end

      test "publisher crash after child commit recovers the handoff before rematching" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.find_or_create_by!(creative: @creative, user: agent, permission: :feedback)
        @rule.update!(data: @rule.data.deep_merge("workflow_rule" => {
          "handler" => { "type" => "agent", "agent_ids" => [ agent.id ] }, "emits" => "workflow_step_completed"
        }))
        child_rule = create_workflow_rule(parent: @workflow, event: "workflow_step_completed")
        parent = Execution.find(dispatch.workflow_execution_id)
        assert parent.open?, parent.reason
        task = Task.create!(name: "Committed responder", agent: agent, creative: @creative, topic_id: @topic.id,
          status: "running", trigger_event_name: "comment_created", workflow_execution_id: parent.id,
          trigger_event_payload: parent.admissions.first.context)
        reply = Comment.create!(creative: @creative, topic: @topic, user: agent, task: task, content: "Committed reply", skip_dispatch: true)
        task.task_actions.create!(action_type: "reply_created", status: "done", payload: { "comment_id" => reply.id })
        task.update!(status: "done")
        child = parent.outboxes.find_by!(key: "child")
        Recovery.outbox(child)
        publication = Publication.new(child, token: child.reload.claim_token)
        original_call = publication.method(:call)
        # Exception bypasses the worker's StandardError retry rescue, like a lost process.
        publication.stub(:call, -> { original_call.call; raise Interrupt }) do
          Publication.stub(:new, ->(*) { publication }) do
            assert_raises(Interrupt) { child.deliver!(child.claim_token) }
          end
        end
        assert_equal "delivering", child.reload.state
        execution = Execution.find_by!(input_event_id: child.context.dig("event", "id"))
        assert_equal "human_handoff", execution.reason
        delivery = CommentNotificationDelivery.find_by!(workflow_execution_id: execution.id)
        child_rule.update!(archived_at: Time.current)
        child.update!(claimed_at: 6.minutes.ago)
        original = child.context.deep_dup
        Orchestration::Selection.stub(:new, ->(*) { flunk "must recover committed child" }) do
          assert_no_difference [ "Execution.count", "Outbox.count", "Task.count", "Comment.count" ] do
            Recovery.outbox(child)
            child.reload.deliver!(child.claim_token)
          end
        end
        assert_equal "completed", child.reload.state
        assert_equal original, child.context
        assert_nil child.ordinary_delivery
        assert_equal "human_handoff", execution.reload.reason
        assert_equal "suppressed", delivery.reload.push_state
        assert_equal 1, Comment.where(notification_key: delivery.delivery_key).count
      end

      test "two independent push recovery connections claim one expired attempt" do
        Recovery.stub(:execution, nil) { dispatch }
        delivery = CommentNotificationDelivery.where.not(workflow_execution_id: nil).first
        delivery.update!(push_state: "enqueued", push_attempts: 1, push_claim_token: "lost", push_claimed_at: 31.minutes.ago)
        gate = Queue.new
        ready = Queue.new
        tokens = Queue.new
        queue = ->(_id, token) do
          tokens << token
          Object.new.tap { |job| job.define_singleton_method(:successfully_enqueued?) { true } }
        end
        WorkflowPushJob.stub(:perform_later, queue) do
          workers = 2.times.map do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                copy = CommentNotificationDelivery.find(delivery.id)
                ready << true
                gate.pop
                copy.enqueue_push!
              end
            end
          end
          2.times { ready.pop }
          2.times { gate << true }
          workers.each(&:value)
        end
        assert_equal 1, tokens.size
        assert_equal 2, delivery.reload.push_attempts
        assert_equal tokens.pop, delivery.push_claim_token
        assert_equal "enqueued", delivery.push_state
      end

      test "database unique constraints own execution outbox and receipt identities" do
        Recovery.stub(:execution, nil) { dispatch }
        receipt = Receipt.first
        execution = receipt.execution
        [ receipt, execution, execution.chain ].each do |record|
          assert_raises(ActiveRecord::RecordNotUnique) do
            record.class.insert_all!([ record.attributes.except("id") ])
          end
        end
        row = execution.outboxes.create!(key: "child", context: {}, due_at: Time.current)
        assert_raises(ActiveRecord::RecordNotUnique) { Outbox.insert_all!([ row.attributes.except("id") ]) }
      end

      private

      def dispatch
        SystemEvents::Dispatcher.dispatch_with_outcome("comment_created", @context,
          source: "drop_trigger", invocation: @invocation)
      end
    end
  end
end
