# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Workflow
    class ExecutionTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper
      include ActiveJob::TestHelper
      self.use_transactional_tests = true

      setup do
        @adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @owner = users(:one)
        @agent = users(:ai_bot)
        @workflow = create_workflow
        @creative = create_workflow_creative(description: "Execution", data: { "context_ids" => [ @workflow.id ] })
        @topic = Topic.create!(creative: @creative, name: "Workflow execution", user: @owner)
        CreativeShare.create!(creative: @creative, user: @agent, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
        @comment = Comment.create!(creative: @creative, topic: @topic, user: @owner, content: "Start", skip_dispatch: true)
        @policy = OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "on" })
        @rule = create_workflow_rule(parent: @workflow, handler: { "type" => "agent", "agent_ids" => [ @agent.id ] })
        @context = @comment.dispatch_payload.deep_stringify_keys.merge("event_name" => "comment_created",
          "event" => SystemEvents::Envelope.root("comment_created", source: "comment_callback").to_h)
      end

      teardown { ActiveJob::Base.queue_adapter = @adapter }

      test "selection stays read only and dispatch owns one frozen admission" do
        selection = Orchestration::AgentOrchestrator.prepare_selection("comment_created", @context)
        assert_equal @rule.id, selection.workflow_rule.creative_id
        assert_no_difference "Execution.count" do
          2.times { Orchestration::AgentOrchestrator.prepare_selection("comment_created", @context) }
        end
        result = dispatch(selection: selection)
        assert result.workflow_handled?
        execution = Execution.find(result.workflow_execution_id)
        assert_equal [ @agent.id ], execution.selected_agent_ids
        assert_equal 1, execution.chain.task_count
        assert_equal 1, execution.chain.step_count
        assert_equal execution.id, execution.admissions.first.context["workflow_execution_id"]
        assert_no_difference [ "Execution.count", "Outbox.count", "Chain.count" ] do
          assert_equal execution.id, dispatch.workflow_execution_id
        end
      end

      test "successful completion reserves one persisted child and reuses its envelope" do
        emits!
        execution = execute
        task = materialize(execution)
        reply = succeed(task)
        Settlement.new(execution).call
        child = execution.outboxes.find_by!(key: "child")
        assert_equal "completed", execution.reload.reason
        assert_equal reply.id, child.context.dig("comment", "id")
        assert_equal [], child.context.dig("chat", "mentioned_users")
        assert_equal @owner.id, child.context["workspace_user_id"]
        assert_equal @agent.id, child.context.dig("sender", "id")
        assert_equal @context.dig("event", "correlation_id"), child.context.dig("event", "correlation_id")
        assert_equal @context.dig("event", "id"), child.context.dig("event", "causation_id")
        assert_equal 1, child.context.dig("event", "depth")
        assert_not child.context.key?("workflow_execution_id")
        before = child.context.deep_dup
        Settlement.new(execution).call
        assert_equal before, child.reload.context
        assert_equal 1, execution.outboxes.where(key: "child").count
      end

      test "human handoff persists a generic unquoted notice and a localized durable push" do
        @owner.update!(locale: "en")
        handler!("human")
        execution = execute
        assert_equal "human_handoff", execution.reason
        assert_equal 0, execution.tasks.count
        delivery = CommentNotificationDelivery.find_by!(workflow_execution_id: execution.id)
        notice = Comment.find(delivery.inbox_comment_id)
        assert_nil notice.quoted_comment_id
        assert_nil notice.user_id
        assert_not_includes notice.content, @comment.content
        assert_equal "Action needed", delivery.title
        assert_equal "enqueued", delivery.push_state
        assert_equal 1, delivery.push_attempts
        assert_equal "workflow_execution:#{execution.id}:recipient:#{@owner.id}", notice.notification_key
        assert_no_difference "Comment.count" do
          dispatch
        end
      end

      test "none and ineligible handlers own their outcome without fallback" do
        handler!("none")
        assert_equal "ignored", execute.reason
        @context["event"] = SystemEvents::Envelope.root("comment_created", source: "comment_callback").to_h
        @rule.update!(data: { "kind" => "workflow_rule", "workflow_rule" => { "on" => "comment_created", "handler" => { "type" => "agent", "agent_ids" => [ @owner.id ] } } })
        assert_equal "no_eligible_agent", execute.reason
      end

      %w[off shadow].each do |mode|
        test "#{mode} and rule save have no workflow effects" do
          handler!("human")
          @policy.update!(config: { "workflow_routing" => mode })
          assert_no_difference [ "Execution.count", "Receipt.count", "Outbox.count", "CommentNotificationDelivery.count" ] do
            @rule.update!(description: "Saved rule")
            result = dispatch
            assert_not result.workflow_handled?
          end
        end
      end

      %w[failed cancelled escalated].each do |status|
        test "#{status} seals without an event and manual retry cannot reopen" do
          emits!
          execution = execute
          task = materialize(execution)
          task.update!(status: status)
          Settlement.new(execution).call
          assert_equal "task_failed", execution.reload.reason
          task.update!(status: "done")
          Settlement.new(execution).call
          assert_equal "task_failed", execution.reload.reason
          assert_nil execution.outboxes.find_by(key: "child")
        end
      end

      test "login waits while running then seals login_required despite a public card" do
        emits!
        execution = execute
        task = materialize(execution)
        task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" => { "retryable" => true }))
        Settlement.new(execution).call
        assert execution.reload.open?
        succeed(task)
        Settlement.new(execution).call
        assert_equal "login_required", execution.reload.reason
        assert_nil execution.outboxes.find_by(key: "child")
      end

      test "review-only success is non-emitting and a deleted finalized anchor precedes it" do
        execution = execute
        task = materialize(execution)
        task.task_actions.create!(action_type: "review_updated", status: "done", payload: {})
        task.update!(status: "done")
        assert_equal "completed_no_anchor", task.workflow_result
        task.task_actions.create!(action_type: "reply_created", status: "done", payload: { comment_id: -1, partial: true })
        assert_equal "completed_no_anchor", task.workflow_result
        task.task_actions.create!(action_type: "reply_created", status: "done", payload: { comment_id: -2 })
        assert_equal "scope_changed", task.workflow_result
      end

      test "empty and placeholder replies do not complete" do
        task = materialize(execute)
        task.update!(status: "done")
        assert_equal "empty_reply", task.workflow_result
        reply = Comment.create!(creative: @creative, topic: @topic, user: @agent, task: task,
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, skip_dispatch: true)
        assert_equal "empty_reply", task.workflow_result
        reply.update!(content: "Usable reply", private: true)
        assert_equal "permission_revoked", task.workflow_result
      end

      test "depth task step and cycle reservations fail atomically" do
        execution = execute
        chain = execution.chain
        assert_equal "depth_exceeded", chain.depth_reason(9)
        assert_equal "invalid_envelope", chain.depth_reason(-1)
        assert_equal "cycle", chain.reservation_reason(@rule.id, 1, 1)
        chain.update!(task_count: 15)
        assert_equal "task_budget_exhausted", chain.reservation_reason(-1, 1, 2)
        chain.update!(step_count: 16)
        assert_equal "step_budget_exhausted", chain.reservation_reason(-1, 1, 1)
        chain.update!(root_depth: 60)
        assert_equal "depth_exceeded", chain.depth_reason(65)
        assert_nil chain.depth_reason(64)
      end

      test "same serialized producer identity acknowledges without another root or notice" do
        handler!("human")
        invocation = { source: "drop_trigger", job_id: SecureRandom.uuid }
        @context["event"]["source"] = "drop_trigger"
        first = dispatch(source: "drop_trigger", invocation: invocation)
        assert_difference "Receipt.count", 0 do
          assert_equal first.workflow_execution_id, dispatch(source: "drop_trigger", invocation: invocation).workflow_execution_id
        end
        assert_raises(ArgumentError) { dispatch(source: "cron", invocation: invocation) }
        @context.delete("event")
        assert_difference "Receipt.count" do
          dispatch(source: "drop_trigger", invocation: invocation.merge(job_id: SecureRandom.uuid))
        end
      end

      test "fixed anchors survive refresh and cannot be coalesced" do
        execution = execute
        task = materialize(execution, status: "queued")
        original = task.trigger_event_payload.deep_dup
        Comment.create!(creative: @creative, topic: @topic, user: @owner, content: "Newer", skip_dispatch: true)
        Orchestration::AgentOrchestrator.send(:refresh_deferred_context!, task)
        assert_equal original, task.reload.trigger_event_payload
        assert_equal [], Orchestration::TaskCoalescer.coalesce!(task)
        assert FixedAnchor.validate!(task)
      end

      test "callback-free topic movement stops an unmaterialized admission" do
        execution = execute
        destination = create_workflow_creative(description: "Destination")
        @topic.update_columns(creative_id: destination.id)
        @comment.update_columns(creative_id: destination.id)
        Recovery.execution(execution)
        assert_equal "scope_changed", execution.reload.reason
        assert_empty execution.tasks
        assert_equal "failed", execution.admissions.first.state
      end

      test "authoritative safety reason survives failed overwrite and input restoration" do
        execution = execute
        task = materialize(execution)
        @comment.update_columns(private: true)
        assert_not FixedAnchor.validate!(task)
        assert_equal "permission_revoked", task.reload.workflow_stop_reason
        task.update_columns(status: "failed")
        @comment.update_columns(private: false)
        Settlement.new(execution).call
        assert_equal "permission_revoked", execution.reload.reason
      end

      test "forged admission marker and parent metadata confer no task identity" do
        execution = execute
        row = execution.admissions.first
        assert DispatchIdentity.valid?(row.context, @agent.id)
        assert_not DispatchIdentity.valid?(row.context.merge("event" => @context["event"].merge("id" => "forged")), @agent.id)
        assert_not DispatchIdentity.valid?(@context.merge("workflow" => { "execution_id" => execution.id }), @agent.id)
      end

      test "dispatch freezes handler and emits from the selected rule" do
        emits!
        selection = Orchestration::AgentOrchestrator.prepare_selection("comment_created", @context)
        handler!("none")
        execution = Execution.find(dispatch(selection: selection).workflow_execution_id)
        assert_equal "agent", execution.handler
        assert_equal "workflow_step_completed", execution.emits
        assert_equal 1, execution.admissions.count
      end

      test "a failed reserved rule cannot run again in the same chain" do
        execution = execute
        task = materialize(execution)
        task.update!(status: "failed")
        Settlement.new(execution).call
        @context["event"]["id"] = SecureRandom.uuid
        second = execute
        assert_equal "cycle", second.reason
        assert_equal 1, second.chain.task_count
        assert_equal 1, second.chain.step_count
      end

      test "one outbox worker materializes one task and provider invocation" do
        execution = execute
        row = execution.admissions.first
        calls = []
        service = ->(task) { calls << task.id; Object.new.tap { |object| object.define_singleton_method(:call) { } } }
        Recovery.execution(execution)
        token = row.reload.claim_token
        assert token
        AiAgentService.stub(:new, service) do
          WorkflowOutboxJob.perform_now(row.id, token)
          WorkflowOutboxJob.perform_now(row.id, token)
        end
        assert_equal 1, execution.tasks.count
        assert_equal 1, calls.size
        assert_equal execution.id, execution.tasks.first.workflow_execution_id
        assert_equal "completed", row.reload.state
        assert_equal "empty_reply", execution.reload.reason
      end

      test "queue crash gap and exhausted outbox attempts stop missing tasks" do
        execution = execute
        row = execution.admissions.first
        row.update!(state: "pending", claim_token: nil, claimed_at: nil, attempts: 0)
        assert_difference "WorkflowOutboxJob.queue_adapter.enqueued_jobs.size" do
          Recovery.outbox(row)
        end
        token = row.reload.claim_token
        assert_no_difference "WorkflowOutboxJob.queue_adapter.enqueued_jobs.size" do
          Recovery.outbox(row)
        end
        travel 6.minutes do
          Recovery.outbox(row.reload)
          assert_not_equal token, row.reload.claim_token
          assert_equal 2, row.attempts
        end
        row.update!(attempts: 3, claimed_at: 6.minutes.ago)
        Recovery.outbox(row)
        assert_equal "delivery_failed", execution.reload.reason
        assert_equal "failed", row.reload.state
      end

      test "a child publishes the same event and the next rule owns it" do
        emits!
        execution = execute
        succeed(materialize(execution))
        Settlement.new(execution).call
        next_rule = create_workflow_rule(parent: @workflow, event: "workflow_step_completed", handler: { "type" => "none" })
        child = execution.outboxes.find_by!(key: "child")
        Publication.new(child).call
        following = execution.chain.executions.find_by!(rule_id: next_rule.id)
        assert_equal "ignored", following.reason
        assert_equal child.context["event"], following.context["event"]
        assert_no_difference "Execution.count" do
          Publication.new(child).call
        end
      end

      [ nil, true, false ].each do |preference|
        test "workflow push preference #{preference.inspect} preserves inbox and bounds transport" do
          @owner.update!(notifications_enabled: preference)
          handler!("human")
          execution = execute
          delivery = CommentNotificationDelivery.find_by!(workflow_execution_id: execution.id)
          delivery.enqueue_push!
          assert_equal "human_handoff", execution.reload.reason
          assert Comment.exists?(delivery.inbox_comment_id)
          expected = preference == false ? "suppressed" : "enqueued"
          assert_equal expected, delivery.reload.push_state
          next if preference == false
          calls = []
          PushNotificationJob.stub(:perform_now, ->(*args, **options) { calls << [ args, options ] }) do
            WorkflowPushJob.perform_now(delivery.id, delivery.push_claim_token)
            WorkflowPushJob.perform_now(delivery.id, delivery.push_claim_token)
          end
          assert_equal 1, calls.size
          assert_equal delivery.title, calls.first.last[:title]
          assert_equal "completed", delivery.reload.push_state
          assert_nil delivery.push_claim_token
        end
      end

      test "queued push keeps its token through minute six and starts a transport clock" do
        delivery = handoff_delivery
        token = delivery.push_claim_token
        travel 6.minutes do
          assert_not delivery.enqueue_push!
          assert_equal token, delivery.reload.push_claim_token
          calls = []
          PushNotificationJob.stub(:perform_now, ->(*) { calls << true }) do
            WorkflowPushJob.perform_now(delivery.id, token)
          end
          assert_equal 1, calls.size
          assert_equal 1, delivery.reload.push_attempts
          assert_equal "completed", delivery.push_state
        end
      end

      test "three expired queue waits can fail with no transport and never enqueue a fourth attempt" do
        delivery = handoff_delivery
        2.times do |index|
          travel 31.minutes do
            delivery.enqueue_push!
            assert_equal index + 2, delivery.reload.push_attempts
          end
          delivery.update!(push_claimed_at: Time.current)
        end
        travel 31.minutes do
          old_token = delivery.push_claim_token
          assert_no_difference "WorkflowPushJob.queue_adapter.enqueued_jobs.size" do
            delivery.enqueue_push!
            WorkflowPushJob.perform_now(delivery.id, old_token)
            delivery.enqueue_push!
          end
        end
        assert_equal "failed", delivery.reload.push_state
        assert_equal 3, delivery.push_attempts
        assert Comment.exists?(delivery.inbox_comment_id)
      end

      test "fast worker and duplicate delivery cannot be regressed by enqueue acknowledgement" do
        delivery = handoff_delivery
        delivery.update!(push_state: "pending", push_claim_token: nil, push_claimed_at: nil, push_attempts: 0)
        fast = ->(id, token) do
          PushNotificationJob.stub(:perform_now, ->(*) { }) do
            WorkflowPushJob.perform_now(id, token)
          end
          Object.new.tap { |job| job.define_singleton_method(:successfully_enqueued?) { true } }
        end
        WorkflowPushJob.stub(:perform_later, fast) { delivery.enqueue_push! }
        assert_equal "completed", delivery.reload.push_state
        assert_nil delivery.push_claim_token
        assert_equal 1, delivery.push_attempts
      end

      test "push enqueue failure releases only its attempt and exhaustion seals delivery" do
        delivery = handoff_delivery
        delivery.update!(push_state: "pending", push_claim_token: nil, push_claimed_at: nil, push_attempts: 0)
        WorkflowPushJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) do
          3.times { delivery.enqueue_push! }
        end
        assert_equal 3, delivery.reload.push_attempts
        assert_equal "failed", delivery.push_state
        assert_equal "human_handoff", Execution.find(delivery.workflow_execution_id).reason
      end

      test "push worker failure is retryable and stale completion cannot acknowledge a new token" do
        delivery = handoff_delivery
        old = delivery.push_claim_token
        PushNotificationJob.stub(:perform_now, ->(*) { raise IOError }) do
          WorkflowPushJob.perform_now(delivery.id, old)
        end
        assert_equal "pending", delivery.reload.push_state
        assert_nil delivery.push_claim_token
        delivery.enqueue_push!
        newer = delivery.reload.push_claim_token
        WorkflowPushJob.perform_now(delivery.id, old)
        assert_equal newer, delivery.reload.push_claim_token
        assert_equal "enqueued", delivery.push_state
      end

      test "sealed handoff push is suppressed after a topic move by shared sweep" do
        delivery = handoff_delivery
        destination = create_workflow_creative(description: "Moved")
        @topic.update_columns(creative_id: destination.id)
        @comment.update_columns(creative_id: destination.id)
        CommentPushDeliverySweepJob.perform_now
        assert_equal "suppressed", delivery.reload.push_state
        assert_equal "human_handoff", Execution.find(delivery.workflow_execution_id).reason
        @topic.update_columns(creative_id: @creative.id)
        @comment.update_columns(creative_id: @creative.id)
        assert_not delivery.enqueue_push!
        assert_equal "suppressed", delivery.reload.push_state
      end

      test "ordinary and login restoration strip every dispatch-scoped marker" do
        task = materialize(execute)
        payload = task.trigger_event_payload
        Orchestration::DeliveryRecord::DISPATCH_SCOPED_KEYS.each { |key| assert payload.key?(key) }
        restored = Orchestration::DeliveryRecord.send(:restored_context, payload, @comment)
        Orchestration::DeliveryRecord::DISPATCH_SCOPED_KEYS.each { |key| assert_not restored.key?(key) }
        assert_equal task.workflow_execution_id, task.reload.trigger_event_payload["workflow_execution_id"]
      end

      test "serialized Drop Trigger retry keeps job_id and post-commit redelivery acknowledges the receipt" do
        handler!("human")
        parent = create_workflow_creative(description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
        CreativeShare.create!(creative: parent, user: @agent, permission: :write)
        @topic.update!(name: DropTriggerJob::DROP_TRIGGER_TOPIC_NAME, primary_agent_id: nil)
        job = DropTriggerJob.new(parent.id, @creative.id)
        @comment.update!(content: job.send(:trigger_content_key, @creative, parent))
        serialized = job.serialize
        create = Receipt.method(:create!)
        attempts = 0
        fail_once = ->(*args, **kwargs) do
          attempts += 1
          raise DropTriggerJob::DispatchFailedError if attempts == 1
          create.call(*args, **kwargs)
        end
        Receipt.stub(:create!, fail_once) { ActiveJob::Base.deserialize(serialized).perform_now }
        assert_empty Receipt.all
        retry_payload = enqueued_jobs.find { |entry| entry[:job] == DropTriggerJob }
        assert_equal job.job_id, retry_payload["job_id"]
        travel 6.seconds do
          perform_enqueued_jobs(only: DropTriggerJob)
        end
        assert_equal 1, Receipt.count
        receipt = Receipt.first
        assert_equal job.job_id, receipt.job_id
        assert_equal "human_handoff", receipt.execution.reason
        assert_no_difference [ "Execution.count", "CommentNotificationDelivery.count" ] do
          ActiveJob::Base.deserialize(serialized).perform_now
        end
        @comment.delete
        @policy.update!(config: { "workflow_routing" => "off" })
        assert_no_difference "Execution.count" do
          ActiveJob::Base.deserialize(serialized).perform_now
        end
      end

      test "both replay and ordinary restored dispatches strip incoming markers and create ordinary tasks" do
        original = materialize(execute)
        reply = Comment.create!(creative: @creative, topic: @topic, user: @agent, task: original, content: "Login", skip_dispatch: true)
        login = CliProxy::InlineLogin.new(reply, @owner)
        login.instance_variable_set(:@workspace, Struct.new(:user_id).new(@owner.id))
        Orchestration::DeliveryRecord::DISPATCH_SCOPED_KEYS.each { |key| assert original.trigger_event_payload.key?(key) }
        replay = login.send(:retry_payload, @comment)
        restored = Orchestration::DeliveryRecord.send(:restored_context, original.trigger_event_payload, @comment)
        [ replay, restored ].each do |context|
          Orchestration::DeliveryRecord::DISPATCH_SCOPED_KEYS.each { |key| assert_not context.key?(key) }
          task = Task.create!(name: "Separate dispatch", agent: @agent, creative: @creative, topic_id: @topic.id,
            trigger_event_name: "comment_created", trigger_event_payload: context)
          assert_nil task.workflow_execution_id
        end
        assert DispatchIdentity.valid?(original.trigger_event_payload, @agent.id)
      end

      test "deleting an input preserves its durable scope stop and never reanchors" do
        execution = execute
        task = materialize(execution, status: "queued")
        original_id = @comment.id
        Comment.create!(creative: @creative, topic: @topic, user: @owner, content: "Surviving source", skip_dispatch: true)
        @comment.destroy!
        assert_equal "cancelled", task.reload.status
        assert_equal "scope_changed", task.workflow_stop_reason
        assert_equal original_id, task.trigger_event_payload.dig("comment", "id")
      end

      test "workflow task start revalidates before early returns and rejects manual terminal retry" do
        execution = execute
        task = materialize(execution, status: "pending")
        assert TaskAdmission.validate_start!(task)
        assert TaskAdmission.start!(task)
        assert_not TaskAdmission.start!(task)
        @comment.update_columns(private: true)
        assert_not FixedAnchor.validate!(task)
        assert_equal "permission_revoked", task.reload.workflow_stop_reason
        task.update_columns(status: "pending")
        @comment.update_columns(private: false)
        Settlement.new(execution).stop!("task_failed")
        assert_not TaskAdmission.validate_start!(task.reload)
        assert task.reload.cancelled?
      end

      test "a lost task after materialization stops instead of waiting forever" do
        execution = execute
        task = materialize(execution)
        execution.admissions.first.finish!
        task.delete
        WorkflowSweepJob.perform_now
        assert_equal "delivery_failed", execution.reload.reason
      end

      test "outbox worker failure and agent permission rejection have bounded durable outcomes" do
        execution = execute
        row = execution.admissions.first
        Recovery.execution(execution)
        AiAgentJob.stub(:perform_now, ->(*) { raise IOError }) do
          WorkflowOutboxJob.perform_now(row.id, row.reload.claim_token)
        end
        assert_equal "pending", row.reload.state
        CreativeShare.where(creative: @creative, user: @agent).delete_all
        Recovery.outbox(row)
        WorkflowOutboxJob.perform_now(row.id, row.reload.claim_token)
        assert_equal "permission_revoked", execution.reload.reason
      end

      test "push worker start renews the clock once and the original queue deadline cannot reclaim it" do
        delivery = handoff_delivery
        token = delivery.push_claim_token
        started = Time.current + 29.minutes
        transport = ->(*) do
          travel_to(started + 2.minutes)
          assert_not delivery.enqueue_push!
          assert_equal "delivering", delivery.reload.push_state
          WorkflowPushJob.perform_now(delivery.id, token)
          assert_equal started.to_i, delivery.reload.push_claimed_at.to_i
        end
        travel_to(started)
        PushNotificationJob.stub(:perform_now, transport) { WorkflowPushJob.perform_now(delivery.id, token) }
        assert_equal "completed", delivery.reload.push_state
        assert_equal 1, delivery.push_attempts
      end

      test "expired delivering worker cannot complete the replacement attempt" do
        delivery = handoff_delivery
        token = delivery.push_claim_token
        delivery.update!(push_state: "delivering", push_claimed_at: 6.minutes.ago)
        delivery.enqueue_push!
        replacement = delivery.reload.push_claim_token
        assert_not_equal token, replacement
        assert_equal 2, delivery.push_attempts
        PushDelivery.new(delivery).send(:finish, token, "completed")
        assert_equal replacement, delivery.reload.push_claim_token
        assert_equal "enqueued", delivery.push_state
      end

      test "sealed start cancels and releases only denied work while duplicates keep their slot" do
        execution = execute
        task = materialize(execution, status: "pending")
        tracker = Orchestration::ResourceTracker.for(@agent)
        tracker.reserve!(task.id)
        Settlement.new(execution).stop!("task_failed")
        released = []
        Orchestration::ResourceTracker.stub(:for, tracker) do
          tracker.stub(:release!, ->(id) { released << id }) do
            assert_not TaskAdmission.start!(task)
          end
        end
        assert task.reload.cancelled?
        assert_equal [ task.id ], released
        task.update_columns(status: "running")
        TaskAdmission.stub(:cleanup, ->(*) { flunk "duplicate must not release another worker" }) do
          assert_not TaskAdmission.start!(task.reload)
        end
      end

      test "last start safety denial releases approval resources and retains its reason" do
        task = materialize(execute, status: "pending_approval")
        @comment.update_columns(private: true)
        cleaned = []
        TaskAdmission.stub(:cleanup, ->(denied) { cleaned << denied.id }) do
          assert_not TaskAdmission.start!(task)
        end
        assert_equal [ task.id ], cleaned
        assert_equal "permission_revoked", task.reload.workflow_stop_reason
      end

      test "offline approval resumption releases workflow resources without a safety reason" do
        execution = execute
        task = materialize(execution, status: "pending_approval")
        @agent.update!(llm_vendor: "anthropic", llm_model: "claude-code")
        tracker = Orchestration::ResourceTracker.for(@agent)
        tracker.reserve!(task.id)
        assert_equal 1, tracker.active_jobs
        AiAgentService.stub(:new, ->(*) { flunk "offline workflow must not call the provider" }) do
          AiAgentJob.perform_now(task)
        end
        assert task.reload.cancelled?
        assert_nil task.workflow_stop_reason
        assert_equal "task_failed", execution.reload.reason
        assert_equal 0, tracker.active_jobs
      end

      test "a stale resumption never cancels or releases another running worker" do
        execution = execute
        task = materialize(execution, status: "pending")
        stale = Task.find(task.id)
        task.update_columns(status: "running")
        tracker = Orchestration::ResourceTracker.for(@agent)
        tracker.reserve!(task.id)
        Settlement.new(execution).stop!("task_failed")
        assert_not TaskAdmission.validate_start!(stale)
        TaskAdmission.reject_resumption!(stale)
        assert task.reload.running?
        assert_equal 1, tracker.active_jobs
        assert_nil task.workflow_stop_reason
      end

      test "late offline and assignment denials preserve a worker that has started" do
        execution = execute
        task = materialize(execution, status: "pending_approval")
        tracker = Orchestration::ResourceTracker.for(@agent)
        tracker.reserve!(task.id)
        stale = Task.find(task.id)
        task.update_columns(status: "running")
        job = AiAgentJob.new
        @agent.stub(:claude_channel_agent?, true) do
          @agent.stub(:claude_channel_online?, false) do
            assert job.send(:reject_offline_resumption?, stale, @agent)
          end
        end
        job.send(:reject_assignment_resumption, stale, @agent)
        assert task.reload.running?
        assert_equal 1, tracker.active_jobs
        assert execution.reload.open?
      end

      test "assignment denial after input withdrawal preserves its safety reason and releases resources" do
        execution = execute
        task = materialize(execution, status: "pending_approval")
        tracker = Orchestration::ResourceTracker.for(@agent)
        tracker.reserve!(task.id)
        @comment.update_columns(private: true)
        AiAgentJob.new.send(:reject_assignment_resumption, task, @agent)
        assert task.reload.cancelled?
        assert_equal "permission_revoked", task.workflow_stop_reason
        assert_equal "permission_revoked", execution.reload.reason
        assert_equal 0, tracker.active_jobs
      end

      test "raw malformed depth is rejected before envelope coercion can authorize execution" do
        @context["event"]["depth"] = "not-a-depth"
        assert_equal "invalid_envelope", execute.reason
        assert_empty Outbox.all
      end

      test "handoff callbacks cannot invalidate a committed producer acknowledgement" do
        handler!("human")
        selection = Orchestration::AgentOrchestrator.prepare_selection("comment_created", @context)
        selection.stub(:commit!, -> { raise IOError }) do
          assert dispatch(selection: selection).workflow_handled?
        end
        assert_equal "human_handoff", Execution.last.reason
        assert_equal 1, CommentNotificationDelivery.where.not(workflow_execution_id: nil).count
      end

      test "fan-in waits for the entire admitted set and anchors the lowest agent ID" do
        execution, tasks = fan_in
        replies = tasks.map do |task|
          reply = Comment.create!(creative: @creative, topic: @topic, user: task.agent, task: task,
            content: "Responder completed", skip_dispatch: true)
          task.task_actions.create!(action_type: "reply_created", status: "done", payload: { comment_id: reply.id })
          reply
        end
        tasks.last.update!(status: "done")
        assert execution.reload.open?
        assert_nil execution.outboxes.find_by(key: "child")
        tasks.first.update!(status: "done")
        child = execution.outboxes.find_by!(key: "child")
        assert_equal replies.first.id, child.context.dig("comment", "id")
        assert_equal tasks.map(&:id), child.context.dig("workflow", "task_ids")
        assert_equal replies.map(&:id), child.context.dig("workflow", "reply_comment_ids")
        assert_equal 2, execution.chain.task_count
      end

      test "a review-only member seals fan-in without substituting another reply" do
        execution, tasks = fan_in
        succeed(tasks.first)
        tasks.last.task_actions.create!(action_type: "review_updated", status: "done", payload: {})
        tasks.last.update!(status: "done")
        assert_equal "completed_no_anchor", execution.reload.reason
        assert_nil execution.outboxes.find_by(key: "child")
      end

      test "a partial-only completion with no reply has no finalized anchor" do
        task = materialize(execute)
        task.task_actions.create!(action_type: "reply_created", status: "done", payload: { comment_id: -1, partial: true })
        task.update!(status: "done")
        assert_equal "empty_reply", task.workflow_result
      end

      test "ordinary cancellation tolerates a task removed before its reanchor lock" do
        task = Task.create!(name: "Concurrent deletion", agent: @agent, status: "pending")
        @comment.stub(:reanchor_locked_task, ->(*) { raise ActiveRecord::RecordNotFound }) do
          assert_not @comment.send(:reanchor_coalesced_task, task)
        end
      end

      test "a stale receipt lookup recovers the database winner after a unique conflict" do
        handler!("human")
        invocation = { source: "drop_trigger", job_id: SecureRandom.uuid }
        @context["event"]["source"] = "drop_trigger"
        first = dispatch(source: "drop_trigger", invocation: invocation)
        @context["event"] = SystemEvents::Envelope.root("comment_created", source: "drop_trigger").to_h
        selection = Orchestration::AgentOrchestrator.prepare_selection("comment_created", @context)
        recover = Receipt.method(:recover)
        stale = true
        Receipt.stub(:recover, ->(identity) { stale ? (stale = false; nil) : recover.call(identity) }) do
          assert_equal first.workflow_execution_id, Admission.new(@context, selection, invocation: invocation).call.workflow_execution_id
        end
        assert_equal 1, Receipt.count
        assert_equal 1, Execution.count
      end

      test "inbox integrity failure rolls back and broadcast failure cannot erase the notice" do
        inbox = Creative.inbox_for(@owner)
        topic = inbox.system_topic(fallback_user: @owner)
        topic.update_columns(name: "Renamed concurrently")
        inbox.stub(:system_topic, topic) do
          assert_raises(ActiveRecord::RecordInvalid) do
            InboxNotice.persist!(inbox: inbox, owner: @owner, key: "invalid", content: "Generic notice")
          end
        end
        topic.update_columns(name: Creative::SYSTEM_TOPIC_NAME)
        notice = InboxNotice.persist!(inbox: inbox, owner: @owner, key: "valid", content: "Generic notice")
        notice.stub(:broadcast_create, -> { raise IOError }) { InboxNotice.send(:broadcast, notice) }
        assert Comment.exists?(notice.id)
      end

      test "outbox enqueue and recovery errors preserve committed identity for the next sweep" do
        execution = execute
        row = execution.admissions.first
        row.update!(claimed_at: 6.minutes.ago)
        WorkflowOutboxJob.stub(:perform_later, nil) { Recovery.outbox(row) }
        assert_equal "pending", row.reload.state
        assert_nil row.claim_token
        Settlement.stub(:new, ->(*) { raise IOError }) { Recovery.execution(execution) }
        assert execution.reload.open?
        Recovery.execution(execution)
        assert_equal "enqueued", row.reload.state
        assert_equal 3, row.attempts
      end

      test "rejected ordinary child enqueue is retried with the persisted envelope" do
        child = fallback_child
        original = child.context.deep_dup
        adapter = AiAgentJob.queue_adapter
        adapter.stub(:enqueue, ->(*) { raise ActiveJob::EnqueueError }) do
          deliver_child(child)
        end
        assert_equal "pending", child.reload.state
        assert_equal 1, child.attempts
        assert_nil child.claim_token
        assert_equal original, child.context
        assert_equal "completed", child.execution.reload.reason

        assert_difference -> { enqueued_jobs.count { |job| job[:job] == AiAgentJob } }, 1 do
          deliver_child(child)
        end
        assert_equal "completed", child.reload.state
        payload = ActiveJob::Arguments.deserialize(enqueued_jobs.reverse.find { |job| job[:job] == AiAgentJob }[:args]).last
        assert_equal original["event"], payload["event"]
        assert_not payload.key?("workflow_execution_id")
      end

      test "rejected delayed child enqueue exhausts bounded recovery without a waiting notice" do
        child = fallback_child
        OrchestratorPolicy.create!(policy_type: "scheduling", config: { "max_concurrent_jobs" => 0 })
        adapter = AiAgentJob.queue_adapter
        adapter.stub(:enqueue_at, ->(*) { raise ActiveJob::EnqueueError }) do
          assert_no_difference "Comment.count" do
            3.times { deliver_child(child) }
          end
        end
        assert_equal "pending", child.reload.state
        assert_equal 3, child.attempts
        Recovery.outbox(child)
        assert_equal "failed", child.reload.state
        assert_equal "delivery_failed", child.reason
        assert_equal "completed", child.execution.reload.reason
        assert_no_difference -> { enqueued_jobs.size } do
          Recovery.outbox(child)
        end
      end

      test "partial ordinary child fanout rejection remains recoverable" do
        child = fallback_child
        second = @agent.dup
        second.assign_attributes(email: "fallback-second@example.test", name: "Fallback second")
        second.save!
        CreativeShare.create!(creative: @creative, user: second, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.create!(creative: @creative, user: second, permission: :feedback)
        OrchestratorPolicy.create!(policy_type: "arbitration", config: { "strategy" => "all", "max_responders" => 2 })
        OrchestratorPolicy.create!(policy_type: "scheduling", config: { "topic_max_concurrent_jobs" => 2 })
        adapter = AiAgentJob.queue_adapter
        enqueue = adapter.method(:enqueue)
        adapter.stub(:enqueue, ->(job) {
          raise ActiveJob::EnqueueError if job.is_a?(AiAgentJob) && job.arguments.first == second.id
          enqueue.call(job)
        }) { deliver_child(child) }
        assert_equal "pending", child.reload.state
        accepted = enqueued_jobs.select { |job| job[:job] == AiAgentJob }
        assert_equal [ @agent.id ], accepted.map { |job| job[:args].first }
        deliver_child(child)
        assert_equal "completed", child.reload.state
        jobs = enqueued_jobs.select { |job| job[:job] == AiAgentJob }
        assert_includes jobs.map { |job| job[:args].first }, second.id
        assert jobs.all? { |job| ActiveJob::Arguments.deserialize(job[:args]).last["event"] == child.context["event"] }
      end

      test "a job reporting unsuccessful enqueue leaves child publication pending" do
        child = fallback_child
        rejected = AiAgentJob.new
        assert_not rejected.successfully_enqueued?
        AiAgentJob.stub(:perform_later, rejected) { deliver_child(child) }
        assert_equal "pending", child.reload.state
        AiAgentJob.stub(:perform_later, nil) { deliver_child(child) }
        assert_equal "pending", child.reload.state
        assert_equal 2, child.attempts
      end

      test "ordinary dispatch keeps legacy enqueue handling without child acknowledgement" do
        child = fallback_child
        AiAgentJob.stub(:perform_later, nil) do
          outcome = SystemEvents::Dispatcher.dispatch_with_outcome("workflow_step_completed", child.context, source: "workflow")
          assert_equal [ @agent.id ], outcome.agents.map(&:id)
          assert_not outcome.workflow_handled?
        end
      end

      private

      def fallback_child
        emits!
        execution = execute
        succeed(materialize(execution))
        Settlement.new(execution).call
        @agent.update!(routing_expression: "true")
        execution.outboxes.find_by!(key: "child")
      end

      def deliver_child(child)
        Recovery.outbox(child.reload)
        child.reload.deliver!(child.claim_token)
      end

      def fan_in
        second = @agent.dup
        second.assign_attributes(email: "workflow-second@example.test", name: "Second workflow agent")
        second.save!
        CreativeShare.create!(creative: @creative, user: second, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.create!(creative: @creative, user: second, permission: :feedback)
        OrchestratorPolicy.create!(policy_type: "arbitration", config: { "strategy" => "all", "max_responders" => 2 })
        data = @rule.data.deep_dup
        data["workflow_rule"]["handler"]["agent_ids"] << second.id
        data["workflow_rule"]["emits"] = "workflow_step_completed"
        @rule.update!(data: data)
        execution = execute
        tasks = execution.admissions.order(:agent_id).map do |row|
          Task.create!(name: "Fan-in responder", agent_id: row.agent_id, creative: @creative, topic_id: @topic.id,
            status: "running", workflow_execution_id: execution.id,
            trigger_event_name: "comment_created", trigger_event_payload: row.context)
        end
        assert_equal 2, tasks.size
        [ execution, tasks ]
      end

      def handoff_delivery
        handler!("human")
        execution = execute
        delivery = CommentNotificationDelivery.find_by!(workflow_execution_id: execution.id)
        delivery.enqueue_push!
        delivery.reload
      end


      def dispatch(source: "comment_callback", **options)
        SystemEvents::Dispatcher.dispatch_with_outcome("comment_created", @context, source: source, **options)
      end

      def execute = Execution.find(dispatch.workflow_execution_id)

      def handler!(type)
        data = @rule.data.deep_dup
        data["workflow_rule"]["handler"] = { "type" => type }
        @rule.update!(data: data)
      end

      def emits!
        data = @rule.data.deep_dup
        data["workflow_rule"]["emits"] = "workflow_step_completed"
        @rule.update!(data: data)
      end

      def materialize(execution, status: "running")
        row = execution.admissions.first!
        Task.create!(name: "Workflow test", agent: @agent, creative: @creative, topic_id: @topic.id,
          status: status, trigger_event_name: "comment_created", trigger_event_payload: row.context,
          workflow_execution_id: execution.id)
      end

      def succeed(task)
        reply = Comment.create!(creative: @creative, topic: @topic, user: @agent, task: task,
          content: "Completed @Another agent: ignored mention", skip_dispatch: true)
        task.task_actions.create!(action_type: "reply_created", status: "done", payload: { "comment_id" => reply.id })
        task.update!(status: "done")
        reply
      end
    end
  end
end
