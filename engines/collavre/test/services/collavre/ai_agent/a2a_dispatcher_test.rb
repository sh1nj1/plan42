# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class A2aDispatcherTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        # LoopBreaker's ping-pong history is cached per creative and outlives the
        # test transaction, so a second dispatch onto the shared fixture creative
        # would be throttled by whatever ran before it.
        Rails.cache.clear
        @creative = creatives(:tshirt)
        @human = users(:one)
        @speaker = build_agent("dispatch_speaker@example.com", "Dispatch Speaker")
        @first = build_agent("dispatch_first@example.com", "Dispatch First")
        @second = build_agent("dispatch_second@example.com", "Dispatch Second")
      end

      teardown do
        ActiveJob::Base.queue_adapter = @original_adapter
      end

      test "every mentioned agent is scheduled" do
        dispatch("@Dispatch Second: you first\n@Dispatch First: then you")

        # Unordered: the topic runs one turn at a time, so the second agent is
        # parked as a waiter rather than enqueued. Both were routed to, which is
        # what used to be lost.
        assert_equal [ @first.id, @second.id ], routed_agent_ids.sort
      end

      test "the payload names every mentioned agent, in mention order" do
        dispatch("@Dispatch Second: you first\n@Dispatch First: then you")

        assert_equal [ @second.id, @first.id ], dispatched_mentioned_ids
      end

      test "a mention behind a human report still reaches the agent" do
        # The regression: the agent system prompt asks for "report to the
        # requester, then hand off", and the handoff used to be dropped because
        # the human's name came first.
        dispatch("@#{@human.name}: done\n@Dispatch First: your turn")

        assert_equal [ @first.id ], routed_agent_ids
      end

      test "the speaker's own mention is not dispatched back to itself" do
        dispatch("@Dispatch Speaker: noted\n@Dispatch First: your turn")

        assert_equal [ @first.id ], routed_agent_ids
      end

      test "a reply that mentions only its own author dispatches nothing" do
        # Quoting your own name is not a handoff. Routing it would hand the
        # agent its own reply as a new trigger — a turn that re-triggers itself.
        dispatch("@Dispatch Speaker: noted, continuing")

        assert_empty routed_agent_ids
      end

      test "the speaker is left out of the loop-prevention record too" do
        dispatch("@Dispatch Speaker: noted\n@Dispatch First: your turn")

        # A self-interaction logged here counts toward ping-pong detection and
        # would throttle the agent for talking to itself.
        assert_equal [ @first.id ], Array(Rails.cache.read(ping_pong_key)).map { |i| i[:to] }
      end

      private

      def ping_pong_key
        "#{Orchestration::LoopBreaker::CACHE_PREFIX}:ping_pong_history:#{@creative.id}"
      end

      def build_agent(email, name)
        agent = User.create!(
          email: email,
          name: name,
          password: "password123",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash",
          searchable: true
        )
        share = CreativeShare.find_or_create_by!(creative: @creative, user: agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: agent.id, permission: :feedback
        )
        agent
      end

      def dispatch(content)
        @reply = Comment.create!(
          creative: @creative, user: @speaker, content: content, skip_dispatch: true
        )
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @reply.topic_id }
        }
        A2aDispatcher.new(agent: @speaker, reply_comment: @reply, context: context).dispatch
      end

      def agent_jobs
        ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job["job_class"] == "Collavre::AiAgentJob" }
      end

      # Every agent this dispatch reached: enqueued for an immediate turn, or
      # parked as a queued waiter behind whoever holds the topic slot.
      def routed_agent_ids
        (agent_jobs.map { |job| job[:args].first } + Task.where(creative_id: @creative.id).pluck(:agent_id)).uniq
      end

      def dispatched_mentioned_ids
        SystemEvents::ContextBuilder.mentioned_ids_in(agent_jobs.first[:args][2])
      end
    end
  end
end
