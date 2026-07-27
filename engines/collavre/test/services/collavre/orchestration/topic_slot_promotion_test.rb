# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # Admission (AiAgentJob) and promotion (dequeue_next_for_topic) are two ways
    # into the same topic slot. Guarding only admission leaves the promotion path
    # free to hand a slot to an agent that already holds one, or to overfill a
    # topic outright — and TaskCoalescer folds only `queued` rows, so two
    # concurrent turns for one agent can never be merged after the fact.
    class TopicSlotPromotionTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Promotion topic", creative: @creative, user: @user)
      end

      def other_agent(tag)
        Collavre::User.create!(
          name: "promo-agent-#{tag}",
          email: "promo-#{tag}-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are agent #{tag}."
        )
      end

      def payload_for(comment)
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => @user.id, "name" => @user.name },
          "comment" => { "id" => comment.id, "content" => comment.content, "user_id" => @user.id }
        }
      end

      def comment(body)
        Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: body, skip_dispatch: true
        )
      end

      def task_for(agent, status:, comment: nil)
        Task.create!(
          name: "Task #{status}", status: status, trigger_event_name: "comment_created",
          agent: agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: payload_for(comment || self.comment("trigger"))
        )
      end

      # A promoted waiter leaves "queued" for good: the test adapter runs its
      # AiAgentJob inline, so it can be anywhere from "pending" to "done" by the
      # time control returns. What matters is that it was let out of the queue.
      def assert_promoted(task, message)
        assert_includes %w[pending running delegated done], task.reload.status, message
      end

      def topic_max!(value)
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "topic_max_concurrent_jobs" => value }
        )
      end

      # topic_max = 1, a live holder, and a waiter behind it. Promotion runs on
      # every terminal task in the topic, including tasks that never held this
      # slot, so it has to re-check occupancy rather than trust its caller.
      test "does not promote a waiter while the topic is at capacity" do
        holder = task_for(other_agent("holder"), status: "running")
        waiter = task_for(@agent, status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", waiter.reload.status,
                     "a full topic must not admit a second turn through the promotion path"
        assert_equal "running", holder.reload.status
      end

      # topic_max = 2 exists to run *different* agents in parallel. An agent with
      # a turn already in flight must stay queued even though the topic has room.
      test "does not promote a waiter whose agent already occupies a slot" do
        topic_max!(2)
        task_for(@agent, status: "running")
        waiter = task_for(@agent, status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", waiter.reload.status,
                     "the same agent must not run two concurrent turns in one topic"
      end

      test "promotes a different agent's waiter into the free slot" do
        topic_max!(2)
        task_for(@agent, status: "running")
        waiter = task_for(other_agent("second"), status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_promoted waiter, "the parallelism topic_max > 1 buys must survive the eligibility guard"
      end

      # The oldest waiter is not always the eligible one. Skipping it entirely
      # would strand every waiter behind a busy agent.
      test "skips an ineligible waiter and promotes the next eligible one" do
        topic_max!(2)
        task_for(@agent, status: "running")
        blocked = task_for(@agent, status: "queued")
        eligible = task_for(other_agent("third"), status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", blocked.reload.status
        assert_promoted eligible, "an eligible waiter behind a blocked one must still run"
      end

      # A deferral is not proof that the topic is full: with topic_max > 1 an
      # agent defers because *it* is busy, while a slot sits free for someone
      # else. Draining only when every occupant is gone strands that waiter until
      # the unrelated holder finishes.
      test "drains another agent's waiter when a slot remains free after deferring" do
        topic_max!(2)
        Orchestration::ResourceTracker.for(@agent).reset!
        task_for(@agent, status: "running")
        stranded = task_for(other_agent("waiting"), status: "queued")

        AiAgentJob.new.perform(@agent.id, "comment_created", payload_for(comment("same agent again")))

        assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                     "the busy agent's new trigger must queue"
        assert_promoted stranded, "the free slot must go to the waiter that can use it"
      ensure
        Orchestration::ResourceTracker.for(@agent).reset!
      end

      # Promotion claims a slot; it must take the same lock admission takes, or
      # the two paths can hand out the same slot concurrently.
      test "claims the promoted slot inside one locked transaction" do
        locked_topic_ids = []
        lock_relation = Struct.new(:sink) do
          def find_by(id:)
            sink << id
            nil
          end
        end.new(locked_topic_ids)

        task_for(@agent, status: "queued")
        baseline_depth = Task.connection.open_transactions
        check_depth = nil
        counting_scope = Task.occupying_topic_slot(@topic.id, @creative.id)

        Topic.stub(:lock, lock_relation) do
          Task.stub(:occupying_topic_slot, ->(*) {
            check_depth ||= Task.connection.open_transactions
            counting_scope
          }) do
            AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
          end
        end

        # The promoted task runs inline here and drains the queue again as it
        # finishes, so the row is locked once per claim attempt — what matters
        # is that no claim skips the lock.
        assert_equal [ @topic.id ], locked_topic_ids.uniq,
                     "promotion must serialize on the same topic row admission uses"
        assert_predicate locked_topic_ids, :any?
        assert_operator check_depth, :>, baseline_depth,
                        "the occupancy check must run inside the claiming transaction"
      end
    end
  end
end
