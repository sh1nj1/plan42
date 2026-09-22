# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # Mention order is who takes the floor: Scheduler#schedule walks the agent
    # array in order and, under topic_max_concurrent_jobs, admits the ones it
    # reaches first and defers the rest. Selection sits between the Matcher that
    # establishes that order and the Scheduler that spends it, so the order has
    # to survive the trip.
    class SelectionMentionOrderTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @low_id_agent = users(:ai_bot)
        @creative = creatives(:tshirt)

        @low_id_agent.update!(searchable: true, routing_expression: nil)
        grant_feedback(@low_id_agent)

        # Created now, so its id sorts AFTER the fixture agent's — mentioning it
        # first is exactly the case an id sort silently reverses.
        @high_id_agent = build_agent
        grant_feedback(@high_id_agent)

        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
      end

      test "keeps the mention order when the later-mentioned agent has the lower id" do
        selected = select_for([ @high_id_agent, @low_id_agent ])

        assert_equal [ @high_id_agent.id, @low_id_agent.id ], selected.map(&:id)
      end

      test "keeps the mention order when it already agrees with id order" do
        selected = select_for([ @low_id_agent, @high_id_agent ])

        assert_equal [ @low_id_agent.id, @high_id_agent.id ], selected.map(&:id)
      end

      test "schedules the first-mentioned agent immediately when the topic admits one" do
        topic = @creative.topics.create!(name: "Floor control", user: @user)
        context = mention_context([ @high_id_agent, @low_id_agent ]).merge(
          "topic" => { "id" => topic.id }
        )
        policy_resolver = PolicyResolver.new(context)
        policy_resolver.stub(:topic_max_concurrent_jobs, 1) do
          agents = Selection.new(context, policy_resolver: policy_resolver).call.agents
          decisions = Scheduler.new(context, policy_resolver: policy_resolver).schedule(agents)

          immediate = decisions.select { |d| d[:timing] == :immediate }.map { |d| d[:agent].id }
          assert_equal [ @high_id_agent.id ], immediate
        end
      end

      private

      def select_for(agents)
        context = mention_context(agents)
        Selection.new(context, policy_resolver: PolicyResolver.new(context)).call.agents
      end

      def mention_context(agents)
        {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => { "mentioned_users" => agents.map { |a| { "id" => a.id } } }
        }
      end

      def build_agent
        User.create!(
          name: "Agent #{SecureRandom.hex(3)}",
          email: "agent_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true,
          routing_expression: nil
        )
      end

      def grant_feedback(agent, creative: @creative)
        share = CreativeShare.find_or_create_by!(creative: creative, user: agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: creative.id, user_id: agent.id, permission: :feedback
        )
      end
    end
  end
end
