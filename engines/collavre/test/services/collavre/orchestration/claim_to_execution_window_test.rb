# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # Promotion claims the topic slot (queued -> pending) and folds the waiters
    # that exist at that instant, but the task then sits `pending` until its
    # AiAgentJob actually starts. A comment arriving in that gap parks a waiter
    # the enqueue-time coalescer cannot fold — it supersedes only `queued`
    # siblings, and the promoted task has already left that status. Both turns
    # were un-started together, which is the invariant coalescing is defined
    # over, so the fold has to happen once more at the moment execution begins.
    class ClaimToExecutionWindowTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Claim window", creative: @creative, user: @user)
      end

      def comment(body, user: @user, quoting: nil)
        Comment.create!(
          creative: @creative, user: user, topic: @topic, content: body,
          quoted_comment: quoting, skip_dispatch: true
        )
      end

      # The Review button quotes an agent's own comment; review_type stays nil.
      def review_request(body = "make it shorter")
        comment(body, quoting: comment("agent draft", user: @agent))
      end

      def task_for(trigger, status:, agent: @agent)
        Task.create!(
          name: "Response to comment_created", status: status,
          trigger_event_name: "comment_created", agent: agent,
          topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => @topic.id },
            "comment" => {
              "id" => trigger.id, "content" => trigger.content, "user_id" => trigger.user_id
            },
            "chat" => { "content" => trigger.content },
            "sender" => sender_for(trigger.user_id)
          }
        )
      end

      # The real payload is a *built* context, so "sender" is always present —
      # and reanchor_sender only rewrites a key that is there.
      def sender_for(user_id)
        SystemEvents::ContextBuilder.new("comment" => { "user_id" => user_id }).build["sender"]
      end

      def merged_ids(task)
        Array(task.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY])
      end

      def notices
        Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
               .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
      end

      test "a waiter parked after promotion is folded into the claimed turn" do
        claimed = task_for(comment("@#{@agent.name}: first"), status: "pending")
        late = comment("@#{@agent.name}: and also this")
        late_waiter = task_for(late, status: "queued")

        AgentOrchestrator.coalesce_at_start!(claimed)

        assert_equal "cancelled", late_waiter.reload.status,
                     "a comment that arrived before execution started must not get its own turn"
        assert_equal 0, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count
      end

      test "the folded comment becomes the anchor and the previous one is merged" do
        first = comment("@#{@agent.name}: first")
        claimed = task_for(first, status: "pending")
        late = comment("@#{@agent.name}: and also this")
        task_for(late, status: "queued")

        AgentOrchestrator.coalesce_at_start!(claimed)

        payload = claimed.reload.trigger_event_payload
        assert_equal late.id, payload.dig("comment", "id"),
                     "the reply anchors on the newest comment, as promotion does"
        assert_includes Array(payload[TaskCoalescer::PAYLOAD_KEY]), first.id,
                        "a session agent only ever sees the trigger — the replaced " \
                        "anchor has to survive as a merged comment"
      end

      # The topic lock orders *task creation*, not comment visibility. A comment
      # commits in its own transaction and its AiAgentJob creates the queued task
      # afterwards, so there is a window where the comment is on screen with no
      # task behind it yet. Re-anchoring onto it would have this turn answer a
      # comment it never absorbed — and once that job does run, it parks a waiter
      # against the now-claimed task and the same comment is answered twice.
      test "does not re-anchor onto a comment whose waiter has not materialised" do
        first = comment("@#{@agent.name}: first")
        claimed = task_for(first, status: "pending")
        folded = comment("@#{@agent.name}: and also this")
        task_for(folded, status: "queued")
        # Committed, dispatched, but its AiAgentJob has not created a task yet.
        unclaimed = comment("@#{@agent.name}: still being dispatched")

        AgentOrchestrator.coalesce_at_start!(claimed)

        payload = claimed.reload.trigger_event_payload
        assert_equal folded.id, payload.dig("comment", "id"),
                     "the anchor may only move to a comment this turn actually absorbed"
        refute_equal unclaimed.id, payload.dig("comment", "id")
        refute_includes Array(payload[TaskCoalescer::PAYLOAD_KEY]), unclaimed.id,
                        "a comment with a turn still coming must not be swallowed by this one"
      end

      test "the sender moves with the anchor when the fold crosses users" do
        claimed = task_for(comment("@#{@agent.name}: first"), status: "pending")
        other = users(:two)
        late = comment("@#{@agent.name}: mine now", user: other)
        task_for(late, status: "queued")

        AgentOrchestrator.coalesce_at_start!(claimed)

        assert_equal sender_for(other.id), claimed.reload.trigger_event_payload["sender"],
                     "the turn now answers #{other.name}'s comment and must say so"
      end

      # Control: the window closes at execution, it does not stay open forever.
      # A comment that arrives once the agent is already talking is a genuinely
      # separate turn, and folding it would silently drop it.
      test "a waiter parked after the turn started keeps its own turn" do
        running = task_for(comment("@#{@agent.name}: first"), status: "running")
        late_waiter = task_for(comment("@#{@agent.name}: later"), status: "queued")

        AgentOrchestrator.coalesce_at_start!(running)

        assert_equal "queued", late_waiter.reload.status
        assert_empty merged_ids(running)
      end

      # Control: the fold must not become a way to disable coalescing's own
      # exclusions. A review is an action bound to one comment either way.
      test "a review request parked after promotion keeps its own turn" do
        claimed = task_for(comment("@#{@agent.name}: first"), status: "pending")
        review_task = task_for(review_request, status: "queued")

        AgentOrchestrator.coalesce_at_start!(claimed)

        assert_equal "queued", review_task.reload.status
        assert_empty merged_ids(claimed)
      end

      test "policy off leaves the late waiter its own turn" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "coalesce_pending_tasks" => false }
        )
        claimed = task_for(comment("@#{@agent.name}: first"), status: "pending")
        late_waiter = task_for(comment("@#{@agent.name}: later"), status: "queued")

        AgentOrchestrator.coalesce_at_start!(claimed)

        assert_equal "queued", late_waiter.reload.status
      end

      # The late waiter posted the topic's "⏳" notice on its way into the
      # queue. Folding it away ends the wait the notice describes, and nothing
      # else will ever take that notice down: removal only happens when a
      # promotion drains a *queued* waiter, and this fold left none.
      test "the waiting notice comes down when the fold drains the queue" do
        claimed = task_for(comment("@#{@agent.name}: first"), status: "pending")
        task_for(comment("@#{@agent.name}: later"), status: "queued")
        AgentOrchestrator.post_topic_concurrency_notice(@creative.id, @topic.id)
        assert_equal 1, notices.count, "fixture precondition: the late waiter posted a notice"

        AgentOrchestrator.coalesce_at_start!(claimed)

        assert_equal 0, notices.count
      end

      # Control: the cleanup is scoped to "nobody is waiting any more", not to
      # "a fold happened". Another agent's waiter is still blocked on this topic
      # and its notice is still true.
      test "the waiting notice stays up while another agent is still waiting" do
        other_agent = Collavre::User.create!(
          name: "window-agent-2", email: "window2-#{SecureRandom.hex(4)}@agent.test",
          password: "password123", llm_vendor: "openai", llm_model: "gpt-4",
          system_prompt: "You are a second agent."
        )
        claimed = task_for(comment("@#{@agent.name}: first"), status: "pending")
        task_for(comment("@#{@agent.name}: later"), status: "queued")
        other_waiter = task_for(comment("@#{other_agent.name}: hello"), status: "queued",
                                agent: other_agent)
        AgentOrchestrator.post_topic_concurrency_notice(@creative.id, @topic.id)
        assert_equal 1, notices.count

        AgentOrchestrator.coalesce_at_start!(claimed)

        assert_equal "queued", other_waiter.reload.status,
                     "another agent's waiter is not this agent's sibling"
        assert_equal 1, notices.count,
                     "someone is still waiting on this topic — the notice is still true"
      end
    end
  end
end
