# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Tools
    class TopicMessageWorkflowTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper

      setup do
        @owner = users(:one)
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
        @workflow = create_workflow
        @creative = create_workflow_creative(description: "Tool workflow", data: { "context_ids" => [ @workflow.id ] })
        @topic = @creative.topics.create!(name: "Destination", user: @owner)
        @caller = create_agent("caller")
        @worker = create_agent("worker")
        @fallback = create_agent("fallback", routing_expression: "true")
        @service = TopicMessageCreateService.new
        OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "on" })
        Current.user = @caller
      end

      teardown { Current.reset }

      test "source-constrained workflow selects its agent instead of the expression fallback" do
        source_rule("agent", agent_ids: [ @worker.id ])

        jobs = capture_agent_jobs { post_message }

        assert_equal [ @worker.id ], jobs.map(&:first)
        assert_equal "a2a", SystemEvents::Envelope.in(jobs.first.last).source
      end

      %w[none human].each do |handler|
        test "source-constrained #{handler} workflow suppresses expression fallback" do
          source_rule(handler)

          assert_empty capture_agent_jobs { post_message }
        end
      end

      [ false, true ].each do |with_parent|
        test "both selections and dispatch share one #{with_parent ? 'child' : 'root'} envelope" do
          source_rule("agent", agent_ids: [ @worker.id ])
          parent = with_parent ? carry_parent : nil
          envelopes = []
          prepare = Orchestration::AgentOrchestrator.method(:prepare_selection)
          observer = lambda do |event, payload, **options|
            envelopes << SystemEvents::Envelope.in(payload)
            prepare.call(event, payload, **options)
          end

          jobs = Orchestration::AgentOrchestrator.stub(:prepare_selection, observer) do
            capture_agent_jobs { post_message }
          end

          assert_equal 2, envelopes.size
          envelope = SystemEvents::Envelope.in(jobs.first.last)
          assert_equal [ envelope, envelope ], envelopes
          assert_equal "comment_created", envelope.name
          assert_equal "a2a", envelope.source
          assert_equal parent ? parent.correlation_id : envelope.id, envelope.correlation_id
          assert_equal parent ? parent.depth + 1 : 0, envelope.depth
          if parent
            assert_equal parent.id, envelope.causation_id
            assert_not_equal parent.id, envelope.id
          else
            assert_nil envelope.causation_id
          end
        end
      end

      test "source-constrained self route without a principal rolls back the comment" do
        source_rule("agent", agent_ids: [ @caller.id ])
        Current.agent_turn = { user: nil, task: nil }

        jobs = capture_agent_jobs do
          error = assert_raises(ArgumentError) { post_message }
          assert_equal I18n.t("collavre.tools.topic_message_create.errors.self_route"), error.message
        end

        assert_empty jobs
        assert_not Comment.exists?(topic: @topic)
      end

      test "reusing the service creates a new envelope for each call and current parent" do
        source_rule("agent", agent_ids: [ @worker.id ])
        parents = []
        jobs = capture_agent_jobs do
          2.times do
            parents << carry_parent
            post_message
          end
          Current.agent_turn = nil
          post_message
        end

        envelopes = jobs.map { |job| SystemEvents::Envelope.in(job.last) }
        assert_equal 3, envelopes.map(&:id).uniq.size
        assert_equal parents.map(&:id), envelopes.first(2).map(&:causation_id)
        assert_equal parents.map(&:correlation_id), envelopes.first(2).map(&:correlation_id)
        assert envelopes.last.root?
        assert_equal envelopes.last.id, envelopes.last.correlation_id
      end

      private

      def create_agent(name, routing_expression: nil)
        agent = User.create!(name: name, email: "topic-workflow-#{name}@example.com", password: "password123",
                             llm_vendor: "openai", llm_model: "gpt-4o", creator: @owner, searchable: true,
                             routing_expression: routing_expression)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback, shared_by: @owner)
        agent
      end

      def source_rule(type, **handler)
        rule = create_workflow_rule(parent: @workflow, handler: { "type" => type }.merge(handler.stringify_keys))
        rule.data["workflow_rule"]["when"] = { "source" => [ "a2a" ] }
        rule.save!
      end

      def carry_parent
        parent = SystemEvents::Envelope.child("comment_created",
          parent: SystemEvents::Envelope.root("comment_created", source: "comment_callback"), source: "a2a")
        task = Task.new(trigger_event_payload: { SystemEvents::Envelope::KEY => parent.to_h })
        Current.agent_turn = { user: @owner, task: task }
        parent
      end

      def post_message
        @service.call(topic_id: @topic.id, content: "Start workflow work")
      end

      def capture_agent_jobs
        jobs = []
        AiAgentJob.stub(:perform_later, ->(*args) { jobs << args }) { yield }
        jobs
      end
    end
  end
end
