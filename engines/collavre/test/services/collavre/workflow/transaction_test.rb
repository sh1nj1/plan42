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
