# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Orchestration
    class SelectionWorkflowTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper

      setup do
        @adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @owner = users(:one)
        @agent = users(:ai_bot)
        @workflow = create_workflow
        @creative = create_workflow_creative(description: "Selection", data: { "context_ids" => [ @workflow.id ] })
        @topic = Topic.create!(creative: @creative, name: "Selection", user: @owner)
        CreativeShare.create!(creative: @creative, user: @agent, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.create!(creative: @creative, user: @agent, permission: :feedback)
        @comment = Comment.create!(creative: @creative, topic: @topic, user: @agent, content: "Continue", skip_dispatch: true)
        @context = @comment.dispatch_payload.deep_stringify_keys.merge(
          "event" => SystemEvents::Envelope.root("comment_created", source: "a2a").to_h)
        @override = { @agent.id => { "sender" => SystemEvents::ContextBuilder.sender_context_for(@owner) } }
        @policy = OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "on" })
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
      end

      teardown { ActiveJob::Base.queue_adapter = @adapter }

      test "different sender-dependent rules cannot merge responders into the base execution" do
        base = rule_for("sender.is_ai == true", "agent", [ @owner.id ])
        rule_for("sender.is_ai == false", "agent", [ @agent.id ])

        selection = select
        assert_empty selection.agents
        execution = dispatch_execution(selection)
        assert_equal base.id, execution.rule_id
        assert_equal "no_eligible_agent", execution.reason
        assert_empty execution.admissions
      end

      %w[human none].each do |handler|
        test "a base #{handler} outcome cannot gain an override workflow responder" do
          base = rule_for("sender.is_ai == true", handler)
          rule_for("sender.is_ai == false", "agent", [ @agent.id ])

          selection = select
          assert_empty selection.agents
          execution = dispatch_execution(selection)
          assert_equal base.id, execution.rule_id
          assert_equal handler == "human" ? "human_handoff" : "ignored", execution.reason
          assert_empty execution.admissions
        end
      end

      test "an override-only workflow cannot run through ordinary dispatch" do
        rule_for("sender.is_ai == false", "agent", [ @agent.id ])
        selection = select
        assert_nil selection.workflow_rule
        assert_empty selection.agents
        assert_no_difference [ "Workflow::Execution.count", "Task.count", "Workflow::Outbox.count" ] do
          assert_empty dispatch(selection).agents
        end
      end

      test "ordinary override fallback cannot join a base workflow" do
        base = rule_for("sender.is_ai == true", "agent", [ @agent.id ])
        @agent.update!(routing_expression: "sender.is_ai == false")

        selection = select
        assert_empty selection.agents
        execution = dispatch_execution(selection)
        assert_equal base.id, execution.rule_id
        assert_equal "no_eligible_agent", execution.reason
      end

      test "the same workflow retains its responder and durable admission" do
        base = rule_for("true", "agent", [ @agent.id ])
        selection = select
        assert_equal [ @agent.id ], selection.agents.map(&:id)
        execution = dispatch_execution(selection)
        assert_equal base.id, execution.rule_id
        assert_equal [ @agent.id ], execution.selected_agent_ids
        assert_equal 1, execution.admissions.count
        assert_equal base.data["workflow_rule"], execution.rule_snapshot
      end

      test "an edited snapshot of the same rule cannot supply a responder" do
        base = rule_for("true", "agent", [ @agent.id ])
        calls = 0
        factory = Matcher.method(:new)
        Matcher.stub(:new, ->(context) {
          calls += 1
          if calls == 2
            data = base.data.deep_dup
            data["workflow_rule"]["future_metadata"] = "changed"
            base.update!(data: data)
          end
          factory.call(context)
        }) do
          selection = select
          assert_empty selection.agents
          assert_equal base.id, selection.workflow_rule.creative_id
          assert_not selection.workflow_snapshot.key?("future_metadata")
        end
      end

      %w[off shadow].each do |mode|
        test "#{mode} preserves ordinary sender overrides without workflow effects" do
          @policy.update!(config: { "workflow_routing" => mode })
          rule_for("sender.is_ai == false", "agent", [ @agent.id ])
          @agent.update!(routing_expression: "sender.is_ai == false")
          assert_no_difference [ "Workflow::Execution.count", "Workflow::Outbox.count", "Comment.count" ] do
            selection = select
            assert_nil selection.workflow_rule
            assert_equal [ @agent.id ], selection.agents.map(&:id)
          end
        end
      end

      test "ordinary matching still accepts the workspace principal override" do
        @agent.update!(routing_expression: "sender.is_ai == false")
        selection = select
        assert_nil selection.workflow_rule
        assert_equal [ @agent.id ], selection.agents.map(&:id)
      end

      test "rejecting a mismatched override preserves the other base responder" do
        worker = User.create!(name: "Workflow worker", email: "selection-worker@example.com", password: "password",
          llm_vendor: "google", llm_model: "gemini-1.5-flash")
        CreativeShare.create!(creative: @creative, user: worker, shared_by: @owner, permission: :feedback)
        CreativeSharesCache.create!(creative: @creative, user: worker, permission: :feedback)
        base = rule_for("sender.is_ai == true", "agent", [ worker.id, @agent.id ])
        rule_for("sender.is_ai == false", "agent", [ @agent.id ])

        selection = select
        assert_equal [ worker.id ], selection.agents.map(&:id)
        execution = dispatch_execution(selection)
        assert_equal base.id, execution.rule_id
        assert_equal [ worker.id ], execution.selected_agent_ids
        assert_equal [ worker.id ], execution.admissions.pluck(:agent_id)
      end

      test "the topic tool cannot schedule an override-only workflow as ordinary work" do
        rule_for("sender.is_ai == false", "agent", [ @agent.id ])
        Current.user = @agent
        Current.agent_turn = { user: @owner }

        assert_no_difference [ "Workflow::Execution.count", "Workflow::Outbox.count", "Task.count" ] do
          assert_no_enqueued_jobs only: AiAgentJob do
            result = Tools::TopicMessageCreateService.new.call(topic_id: @topic.id, content: "Use the carried principal")
            assert_equal @agent.id, Comment.find(result[:id]).user_id
          end
        end
      ensure
        Current.reset
      end

      private

      def rule_for(condition, handler, agent_ids = [])
        rule = create_workflow_rule(parent: @workflow, handler: { "type" => handler, "agent_ids" => agent_ids })
        data = rule.data.deep_dup
        data["workflow_rule"]["when"] = { "liquid" => condition }
        rule.update!(data: data)
        rule
      end

      def select
        AgentOrchestrator.prepare_selection("comment_created", @context, candidate_overrides: @override)
      end

      def dispatch(selection)
        SystemEvents::Dispatcher.dispatch_with_outcome("comment_created", @context, source: "a2a", selection: selection)
      end

      def dispatch_execution(selection)
        result = dispatch(selection)
        assert result.workflow_handled?
        Workflow::Execution.find(result.workflow_execution_id)
      end
    end
  end
end
