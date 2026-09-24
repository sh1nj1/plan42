# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Workflow
    class InvocationTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper
      include ActiveJob::TestHelper

      teardown { ActiveJob::Base.queue_adapter = @adapter }

      setup do
        @adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @owner, @agent = users(:one), users(:ai_bot)
        @workflow = create_workflow
        @creative = create_workflow_creative(description: "Feed", data: { "context_ids" => [ @workflow.id ] })
        @source_topic = @creative.topics.create!(name: "Feed input", user: @owner)
        CreativeShare.create!(creative: @creative, user: @agent, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
        @source = @creative.comments.create!(topic: @source_topic, user: @owner, content: "Article to analyze", skip_dispatch: true)
        @rule = create_workflow_rule(parent: @workflow, description: "Analyze the article and save the result.",
          handler: { "type" => "agent", "agent_ids" => [ @agent.id ] })
        @policy = OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "on" })
        @context = @source.dispatch_payload.deep_stringify_keys.merge("event_name" => "comment_created",
          "event" => SystemEvents::Envelope.root("comment_created", source: "comment_callback").to_h)
      end

      test "default Main message anchors the real AI task and keeps the input untouched" do
        execution = execute
        row = execution.admissions.first!
        message = Comment.find(row.context.dig("comment", "id"))
        assert_equal "Main", message.topic.name
        assert_equal @creative.id, message.creative_id
        assert_equal @rule.description, message.content
        assert_equal @owner.id, message.user_id
        assert_not message.review_message?
        assert_equal @source.id, execution.context.dig("comment", "id")
        assert_equal @source_topic.id, @source.reload.topic_id
        assert_equal @context["event"], row.context["event"]
        seen = []
        service = ->(task) { seen << task; Object.new.tap { |object| object.define_singleton_method(:call) { } } }
        Recovery.execution(execution)
        AiAgentService.stub(:new, service) { WorkflowOutboxJob.perform_now(row.id, row.reload.claim_token) }
        task = seen.fetch(0)
        assert_equal message.topic_id, task.topic_id
        assert_equal message.id, task.trigger_event_payload.dig("comment", "id")
        assert_equal execution.id, task.workflow_execution_id
        assert_equal @owner, AiAgent::TaskWorkspaceUser.resolve(task)
      end

      test "named topic is reused and missing topics are created once" do
        configure("topic_name" => "Analysis")
        assert_difference "Topic.count", 1 do
          @execution = execute
        end
        destination = invocation(@execution).topic
        new_event!
        assert_no_difference "Topic.count" do
          assert_equal destination.id, invocation(execute).topic_id
        end
      end

      test "empty or whitespace name selects Main and surrounding whitespace is trimmed" do
        [ "", "   ", " Main " ].each do |name|
          configure("topic_name" => name)
          new_event!
          assert_equal "Main", invocation(execute).topic.name
        end
      end

      test "retry reuses the message and freezes rule text" do
        execution = execute
        original = invocation(execution)
        @rule.update!(description: "Changed after admission")
        assert_no_difference [ "Comment.count", "Execution.count", "Outbox.count" ] do
          2.times { assert_equal execution.id, execute.id }
          2.times { Recovery.execution(execution) }
        end
        assert_equal "Analyze the article and save the result.", original.reload.content
      end

      test "topic creation validation race reuses the concurrent winner" do
        execution = execute
        destination = invocation(execution).topic
        service = Invocation.new(execution)
        service.instance_variable_set(:@creative, @creative)
        scope = @creative.topics
        failure = ActiveRecord::RecordInvalid.new(destination)
        scope.stub(:find_or_create_by!, ->(*) { raise failure }) do
          assert_equal destination.id, service.topic.id
        end
      end

      test "outer rollback removes the message topic and execution" do
        assert_no_difference [ "Comment.count", "Topic.count", "Execution.count", "Outbox.count" ] do
          Execution.transaction do
            execute
            raise ActiveRecord::Rollback
          end
        end
      end

      test "off and shadow create no messages topics or executions" do
        %w[off shadow].each do |mode|
          @policy.update!(config: { "workflow_routing" => mode })
          assert_no_difference [ "Comment.count", "Topic.count", "Execution.count" ] do
            Orchestration::AgentOrchestrator.prepare_selection("comment_created", @context)
          end
        end
      end

      test "archived History session and inbox System destinations cannot run" do
        destination = @creative.topics.create!(name: "Blocked", user: @owner, archived_at: Time.current)
        configure("topic_name" => destination.name)
        assert_blocked
        destination.update!(archived_at: nil, system_kind: "history")
        assert_blocked
        destination.update!(system_kind: nil, session_id: "external-session")
        assert_blocked
        destination.update!(session_id: nil, name: Creative::SYSTEM_TOPIC_NAME)
        @creative.update!(data: @creative.data.merge("kind" => "inbox"))
        configure("topic_name" => destination.name)
        assert_blocked
      end

      test "reserved History is rejected before creating a destination" do
        configure("topic_name" => " History ")
        assert_no_difference [ "Topic.count", "Outbox.count" ] do
          assert_blocked
        end
        assert_equal Creative::HISTORY_TOPIC_NAME, @creative.history_topic.name
      end

      test "source edits do not change admitted prompt or channel inputs" do
        execution = execute
        context = execution.admissions.first!.context
        original = @source.content
        @source.update!(content: "Edited after admission")
        2.times do
          prompt = SourceMessage.prepend_to("Instruction", context, @agent)
          assert_includes prompt, original
          assert_not_includes prompt, @source.content
          deliveries = []
          ActionCable.server.stub(:broadcast, ->(channel, data) { deliveries << data }) do
            AiAgent::ClaudeChannelAdapter.new(agent: @agent, context: context).deliver
          end
          assert_includes deliveries.first.fetch(:comment)[:content], original
          assert_not_includes deliveries.first.fetch(:comment)[:content], @source.content
        end
        @source.update!(private: true)
        assert_equal "Instruction", SourceMessage.prepend_to("Instruction", context, @agent)
      end

      test "destination archive or movement after admission invalidates the fixed anchor" do
        execution = execute
        row = execution.admissions.first!
        topic = invocation(execution).topic
        topic.update!(archived_at: Time.current)
        assert_equal "scope_changed", Safety.new(execution.reload).reason
        topic.update!(archived_at: nil, name: "Moved execution", creative: create_workflow_creative(description: "Other"))
        assert_equal "scope_changed", Safety.new(execution.reload).reason
        assert_not TaskAdmission.permitted?(row.context, @agent)
      end

      test "source withdrawal and invocation withdrawal both stop admitted tasks" do
        execution = execute
        row = execution.admissions.first!
        task = Task.create!(name: "Pending", agent: @agent, creative: @creative,
          topic_id: row.context.dig("topic", "id"), status: "queued",
          workflow_execution_id: execution.id, trigger_event_name: "comment_created", trigger_event_payload: row.context)
        @source.update!(private: true)
        assert_equal "cancelled", task.reload.status
        assert_equal "permission_revoked", task.workflow_stop_reason
        @source.update!(private: false)
        invocation(execution).update!(private: true)
        assert_equal "permission_revoked", Safety.new(execution.reload).reason
      end

      test "destination scheduling quota is used while routing remains source scoped" do
        destination = @creative.main_topic
        OrchestratorPolicy.create!(policy_type: "scheduling", scope_type: "Topic", scope_id: destination.id,
          priority: 100, config: { "daily_token_limit" => 0 })
        assert_no_difference "Comment.count" do
          assert_equal "scheduler_rejected", execute.reason
        end
      end

      test "source enabled routing executes in destination with shadow matching policy" do
        @policy.update!(scope_type: "Topic", scope_id: @source_topic.id)
        execution = execute
        assert_nil Safety.new(execution).reason
        assert_equal "Main", invocation(execution).topic.name
      end

      test "rule mentions are content and do not widen designated responders" do
        @rule.update!(description: "@Another agent: analyze this")
        execution = execute
        assert_equal [ @agent.id ], execution.admissions.pluck(:agent_id)
        assert_equal [], execution.admissions.first.context.dig("chat", "mentioned_users")
        assert_equal 1, Execution.count
      end

      test "authorized source reaches the actual trigger prompt and forged or private source does not" do
        execution = execute
        context = execution.admissions.first!.context
        message = invocation(execution)
        messages = AiAgent::MessageBuilder.new(agent: @agent, context: context, original_comment: message).build[:messages]
        prompt = messages.find { |item| item[:kind] == :trigger }[:parts].filter_map { |part| part[:text] }.join
        assert_includes prompt, @source.content
        assert_includes prompt, "comment_id=#{@source.id}"
        assert_includes prompt, @rule.description
        assert_equal "Instruction", SourceMessage.prepend_to("Instruction", {}, @agent)
        @source.update!(private: true)
        assert_equal "Instruction", SourceMessage.prepend_to("Instruction", context, @agent)
      end

      test "source images reach the trigger only while the admitted source is authorized" do
        @source.images.attach(io: StringIO.new(Base64.decode64(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )), filename: "source.png", content_type: "image/png")
        @source.update!(content: "")
        @context["comment"]["content"] = ""
        execution = execute
        context = execution.admissions.first!.context
        message = invocation(execution)
        images = lambda do |payload, agent = @agent|
          messages = AiAgent::MessageBuilder.new(agent: agent, context: payload, original_comment: message).build[:messages]
          messages.find { |item| item[:kind] == :trigger }[:parts].filter_map { |part| part[:image] }
        end
        2.times { assert_equal @source.images.map(&:blob), images.call(context) }
        assert_empty images.call(context.deep_merge("comment" => { "id" => @source.id }))
        assert_empty images.call(context, users(:two))
        @source.update!(private: true)
        assert_empty images.call(context)
        @source.update!(private: false, topic: @creative.main_topic)
        assert_empty images.call(context)
        @source.destroy!
        assert_empty images.call(context)
      end

      test "channel dispatch receives source context along with the visible rule instruction" do
        execution = execute
        context = execution.admissions.first!.context
        deliveries = []
        ActionCable.server.stub(:broadcast, ->(channel, data) { deliveries << data }) do
          AiAgent::ClaudeChannelAdapter.new(agent: @agent, context: context).deliver
        end
        message = deliveries.first.fetch(:comment)
        assert_equal invocation(execution).id, message[:id]
        assert_includes message[:content], @source.content
        assert_includes message[:content], @rule.description
        assert_includes message[:content], "comment_id=#{@source.id}"
      end

      test "cross topic continuation keeps the chain and once per rule limit" do
        configure("emits" => "comment_created", "topic_name" => "Analysis")
        execution = execute
        row = execution.admissions.first!
        task = Task.create!(name: "Completed", agent: @agent, creative: @creative,
          topic_id: row.context.dig("topic", "id"), status: "running",
          workflow_execution_id: execution.id, trigger_event_name: "comment_created", trigger_event_payload: row.context)
        reply = @creative.comments.create!(topic_id: task.topic_id, user: @agent, task: task, content: "Result", skip_dispatch: true)
        task.task_actions.create!(action_type: "reply_created", status: "done", payload: { "comment_id" => reply.id })
        task.update!(status: "done")
        Settlement.new(execution).call
        child = execution.outboxes.find_by!(key: "child")
        Recovery.outbox(child)
        child.reload.deliver!(child.claim_token)
        child_execution = Execution.find_by!(input_event_id: child.context.dig("event", "id"))
        assert_equal execution.chain_id, child_execution.chain_id
        assert_equal "cycle", child_execution.reason
        assert_equal 1, execution.chain.reload.task_count
        assert_equal child_execution.id, Recovery.dispatch(child.context).workflow_execution_id
        assert_nil Continuation.chain_for(child.context.deep_merge("topic" => { "id" => @source_topic.id }))
        assert_nil Continuation.chain_for("workflow" => { "execution_id" => -1 })
      end

      private

      def configure(attributes)
        @rule.update!(data: @rule.data.deep_merge("workflow_rule" => attributes))
      end

      def new_event!
        @context["event"] = SystemEvents::Envelope.root("comment_created", source: "comment_callback").to_h
      end

      def execute
        outcome = SystemEvents::Dispatcher.dispatch_with_outcome("comment_created", @context, source: "comment_callback")
        Execution.find(outcome.workflow_execution_id)
      end

      def invocation(execution)
        Comment.find(execution.context.dig("invocation", "comment", "id"))
      end

      def assert_blocked
        new_event!
        assert_no_difference "Comment.count" do
          assert_equal "scope_changed", execute.reason
        end
      end
    end
  end
end
