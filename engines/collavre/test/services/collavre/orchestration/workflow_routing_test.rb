# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Orchestration
    class WorkflowRoutingTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper

      setup do
        @user = users(:one)
        @agent = users(:ai_bot)
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
        @agent.reload.update!(routing_expression: "true")
        @workflow = create_workflow
        @creative = create_workflow_creative(description: "Routing", data: { "context_ids" => [ @workflow.id ] })
        grant_feedback(@agent)
        @other = User.create!(email: "workflow-agent@example.com", name: "Workflow agent", password: "password",
                              llm_vendor: "openai", routing_expression: nil)
        grant_feedback(@other)
        @context = { "creative" => { "id" => @creative.id }, "event_name" => "comment_created", "chat" => {} }
        @policy = OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "on" })
      end

      test "no pinned workflow falls back to agent routing" do
        @creative.update!(data: {})
        assert_equal [ @agent ], match
      end

      test "an unconditional rule chooses its agent exclusively" do
        agent_rule
        assert_equal [ @other ], match
      end

      test "a shared workflow pin chooses the origin rule agent instead of the expression agent" do
        agent_rule
        linked = @workflow.create_linked_creative_for_user(users(:two))
        @creative.update!(data: { "context_ids" => [ linked.id ] })

        assert_equal [ @other ], match
      end

      test "first matching rule wins" do
        agent_rule(sequence: 1)
        agent_rule(agent: @agent, sequence: 2)
        assert_equal [ @other ], match
      end

      test "a condition miss continues to the next rule" do
        rule = agent_rule(agent: @agent, sequence: 1)
        rule.data["workflow_rule"]["when"] = { "body_contains" => [ "missing" ] }
        rule.save!
        agent_rule(sequence: 2)
        assert_equal [ @other ], match
      end

      test "Liquid failures identify the rule without exposing its condition in either routing mode" do
        rule = agent_rule(sequence: 1)
        rule.data["workflow_rule"]["when"] = { "liquid" => "{% confidential_customer_tag %}" }
        rule.save!
        agent_rule(sequence: 2)

        %w[on shadow].each do |routing_mode|
          mode(routing_mode)
          lines = []
          Rails.logger.stub(:error, ->(line) { lines << line }) do
            assert_equal [ routing_mode == "on" ? @other : @agent ], match
          end
          assert_equal [ "[Workflow::Conditions] Liquid error=Liquid::SyntaxError rule_id=#{rule.id}" ], lines
        end
      end

      %w[none human].each do |type|
        test "matched #{type} blocks expression evaluation" do
          create_workflow_rule(parent: @workflow, handler: { "type" => type })
          assert_exclusive_empty
        end
      end

      test "unauthorized agents block fallback and warn" do
        agent_rule
        CreativeSharesCache.where(creative: @creative, user: @other).delete_all
        CreativeShare.where(creative: @creative, user: @other).delete_all
        warnings = []
        Rails.logger.stub(:warn, ->(line) { warnings << line }) { assert_exclusive_empty }
        assert warnings.any? { |line| line.include?("no_eligible_responder") }
      end

      test "workflow agents obey inbox confinement" do
        @creative.update!(data: @creative.data.merge("kind" => "inbox"))
        @other.update!(llm_vendor: "anthropic", llm_model: "claude-code")
        AgentSubscription.create!(agent: @other, token: SecureRandom.hex(8))
        agent_rule
        assert_exclusive_empty
      end

      test "own pins precede inherited workflow pins" do
        inherited = create_workflow
        parent = create_workflow_creative(description: "Parent", data: { "context_ids" => [ inherited.id ] })
        @creative.update!(parent: parent)
        create_workflow_rule(parent: inherited, handler: { "type" => "none" })
        agent_rule
        assert_equal [ @other ], match
      end

      test "disabled workflow pins fall back" do
        agent_rule
        @creative.update!(data: @creative.data.merge("disabled_context_ids" => [ @workflow.id ]))
        assert_equal [ @agent ], match
      end

      test "event mismatch falls back" do
        agent_rule
        @context["event_name"] = "other_event"
        assert_equal [ @agent ], match
      end

      test "invalid rule JSON is skipped before a valid rule" do
        create_workflow_rule(parent: @workflow, sequence: 1).update!(data: {
          "kind" => "workflow_rule", "workflow_rule" => "bad JSON structure"
        })
        agent_rule(sequence: 2)
        assert_equal [ @other ], match
      end

      test "off never constructs a workflow resolver" do
        mode("off")
        agent_rule
        Workflow::Resolver.stub(:new, ->(*) { flunk "off must not resolve workflows" }) do
          assert_equal [ @agent ], match
        end
      end

      test "shadow mismatch returns exact expression result and logs the decision" do
        mode("shadow")
        agent_rule
        result = [ @agent ]
        matcher = Matcher.new(@context)
        lines = capture_shadow do
          matcher.stub(:match_by_expression, result) { assert_same result, matcher.match }
        end
        assert_equal 1, lines.size
        assert_includes lines.first, "agree=false"
        assert_includes lines.first, "workflow=[#{@other.id}]"
        assert_includes lines.first, "expression=[#{@agent.id}]"
        assert_includes lines.first, "rules=1"
      end

      test "shadow resolver failure is isolated and never retried for diagnostics" do
        mode("shadow")
        calls = 0
        resolver = Object.new
        resolver.define_singleton_method(:rules) { calls += 1; raise "private content" }
        lines = capture_shadow do
          Workflow::Resolver.stub(:new, resolver) { assert_equal [ @agent ], match }
        end
        assert_equal 1, calls
        assert_equal 1, lines.size
        assert_includes lines.first, 'error="RuntimeError"'
        refute_includes lines.first, "private content"
      end

      test "mention wins before workflow resolution" do
        agent_rule
        @context["chat"] = { "mentioned_user" => { "id" => @agent.id } }
        Workflow::Resolver.stub(:new, ->(*) { flunk "mention must win" }) { assert_equal [ @agent ], match }
      end

      test "primary agent wins before workflow resolution" do
        agent_rule
        topic = @creative.topics.create!(name: "Assigned", user: @user)
        topic.set_primary_agent!(@agent)
        @context["topic"] = { "id" => topic.id }
        Workflow::Resolver.stub(:new, ->(*) { flunk "primary must win" }) { assert_equal [ @agent ], match }
      end

      test "workflow dispatch remains permitted by assignment revalidation entry points" do
        agent_rule
        topic = @creative.topics.create!(name: "Unassigned", user: @user)
        @context["topic"] = { "id" => topic.id }
        matcher = Matcher.new(@context)
        assert_equal [ @other ], matcher.match
        assert matcher.assignment_permits?(@other)
        assert Matcher.permits_assignment?(@context, @other)
        assert_equal @context, Matcher.prepare_waiting_payload(@context, @other)
      end

      test "archived workflow and rule creatives do not route" do
        rule = agent_rule
        rule.update!(archived_at: Time.current)
        assert_equal [ @agent ], match
        rule.update!(archived_at: nil)
        @workflow.update!(archived_at: Time.current)
        assert_equal [ @agent ], match
      end

      test "rules above MAX_RULES cannot route and warn" do
        Workflow::Resolver::MAX_RULES.times do |index|
          rule = agent_rule(sequence: index)
          rule.data["workflow_rule"]["when"] = { "body_contains" => [ "absent" ] }
          rule.save!
        end
        agent_rule(sequence: Workflow::Resolver::MAX_RULES)
        warnings = []
        Rails.logger.stub(:warn, ->(line) { warnings << line }) { assert_equal [ @agent ], match }
        assert warnings.any? { |line| line.include?("Discarded 1 valid rules") }
      end

      test "review author wins over mention primary and workflow" do
        agent_rule
        topic = @creative.topics.create!(name: "Review", user: @user)
        topic.set_primary_agent!(@other)
        quote = @creative.comments.create!(user: @agent, topic: topic, content: "Draft")
        review = @creative.comments.create!(user: @user, topic: topic, content: "Revise", quoted_comment: quote)
        @context.merge!("topic" => { "id" => topic.id }, "comment" => { "id" => review.id },
                        "chat" => { "mentioned_user" => { "id" => @other.id } })
        Workflow::Resolver.stub(:new, ->(*) { flunk "review must win" }) { assert_equal [ @agent ], match }
      end

      test "shadow miss and empty expression agree" do
        mode("shadow")
        @agent.update!(routing_expression: nil)
        lines = capture_shadow { assert_empty match }
        assert_includes lines.first, "agree=true"
        assert_includes lines.first, "workflow=[] expression=[]"
        assert_includes lines.first, "rules=0"
      end

      test "shadow compares sorted IDs while preserving expression order" do
        mode("shadow")
        create_workflow_rule(parent: @workflow, handler: { "type" => "agent", "agent_ids" => [ @other.id, @agent.id ] })
        result = [ @other, @agent ].sort_by(&:id).reverse
        matcher = Matcher.new(@context)
        lines = capture_shadow do
          matcher.stub(:match_by_expression, result) { assert_same result, matcher.match }
        end
        assert_includes lines.first, "agree=true"
      end

      test "on propagates unexpected workflow errors" do
        Workflow::Resolver.stub(:new, ->(*) { raise "resolver failed" }) do
          assert_raises(RuntimeError) { match }
        end
      end

      test "deleted and human agent IDs are exclusive ineligible decisions" do
        rule = create_workflow_rule(parent: @workflow, handler: { "type" => "agent", "agent_ids" => [ @other.id ] })
        @other.destroy!
        assert_exclusive_empty
        rule.data["workflow_rule"]["handler"]["agent_ids"] = [ @user.id ]
        rule.save!
        assert_exclusive_empty
      end

      test "authorized workflow agents are returned in ID order" do
        create_workflow_rule(parent: @workflow, handler: {
          "type" => "agent", "agent_ids" => [ @other.id, @agent.id, @user.id, @other.id ]
        })
        assert_equal [ @agent, @other ].sort_by(&:id), match
      end

      test "shadow logger failures cannot kill fallback routing even after workflow errors" do
        mode("shadow")
        Rails.logger.stub(:info, ->(*) { raise "logger failed" }) do
          assert_equal [ @agent ], match
          Workflow::Resolver.stub(:new, ->(*) { raise "resolver failed" }) do
            assert_equal [ @agent ], match
          end
        end
      end

      test "shadow escapes caller metadata into a single parseable line" do
        mode("shadow")
        @context["event_name"] = "caller\nevent\twith spaces"
        @context["event"] = SystemEvents::Envelope.root("comment_created").with(
          correlation_id: "request\nforged=true \"quoted\""
        ).to_h
        lines = capture_shadow { assert_equal [ @agent ], match }
        assert_equal 1, lines.size
        assert_equal 1, lines.first.lines.size
        assert_includes lines.first, "event=#{@context['event_name'].to_json}"
        assert_includes lines.first, "correlation_id=#{@context.dig('event', 'correlation_id').to_json}"
      end

      test "shadow diagnostic encoding errors cannot interrupt expression routing" do
        mode("shadow")
        @context["event"] = SystemEvents::Envelope.root("comment_created").with(
          correlation_id: "\xFF".dup.force_encoding(Encoding::UTF_8)
        ).to_h
        assert_equal [ @agent ], match
      end

      test "shadow condition failures are isolated and error metadata resets on recovery" do
        mode("shadow")
        agent_rule
        matcher = Matcher.new(@context)
        lines = capture_shadow do
          Workflow::Conditions.stub(:match?, ->(*) { raise "private condition content" }) do
            assert_equal [ @agent ], matcher.match
          end
          assert_equal [ @agent ], matcher.match
        end
        assert_includes lines.first, 'error="RuntimeError"'
        assert_includes lines.last, "error=null"
        assert_includes lines.last, "rules=1"
        refute_includes lines.join, "private condition content"
      end

      test "shadow memoizes rule resolution including its diagnostic count" do
        mode("shadow")
        agent_rule
        resolver = Workflow::Resolver.new(@context)
        calls = 0
        original = resolver.method(:rules)
        resolver.define_singleton_method(:rules) { calls += 1; original.call }
        matcher = Matcher.new(@context)
        Workflow::Resolver.stub(:new, resolver) do
          capture_shadow { 2.times { assert_equal [ @agent ], matcher.match } }
        end
        assert_equal 1, calls
      end

      test "workflow misses retain live channel and expression participation behavior" do
        @other.update!(llm_vendor: "anthropic", llm_model: "claude-code")
        subscription = AgentSubscription.create!(agent: @other, token: SecureRandom.hex(8))
        assert_equal [ @agent, @other ].sort_by(&:id), match
        @other.update!(routing_expression: "false")
        assert_equal [ @agent ], match
        @other.update!(routing_expression: "true")
        subscription.destroy!
        assert_equal [ @agent ], match
      end

      private

      def grant_feedback(agent)
        CreativeShare.create!(creative: @creative, user: agent, permission: "feedback")
        CreativeSharesCache.find_or_create_by!(creative: @creative, user: agent, permission: :feedback)
      end

      def agent_rule(agent: @other, **attributes)
        create_workflow_rule(parent: @workflow, handler: { "type" => "agent", "agent_ids" => [ agent.id ] }, **attributes)
      end

      def mode(value)
        @policy.update!(config: { "workflow_routing" => value })
      end

      def match
        Matcher.new(@context).match
      end

      def assert_exclusive_empty
        matcher = Matcher.new(@context)
        matcher.stub(:match_by_expression, -> { flunk "matched workflow must not evaluate expressions" }) do
          assert_empty matcher.match
        end
      end

      def capture_shadow
        lines = []
        Rails.logger.stub(:info, ->(line) { lines << line if line.include?("workflow_shadow") }) { yield }
        lines
      end
    end
  end
end
