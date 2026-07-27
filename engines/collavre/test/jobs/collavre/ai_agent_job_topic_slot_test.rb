# frozen_string_literal: true

require "test_helper"

module Collavre
  # The Scheduler's topic-concurrency check counts Task rows, but for an
  # :immediate decision that row is only created inside AiAgentJob. A burst of
  # comments dispatched before the first job runs therefore all see an empty
  # topic and are all judged :immediate — several turns run at once in a topic
  # limited to one. AiAgentJob re-checks at row-creation time.
  class AiAgentJobTopicSlotTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @agent = users(:ai_bot)
      @topic = Topic.create!(name: "Slot topic", creative: @creative, user: @user)
      Orchestration::ResourceTracker.for(@agent).reset!
    end

    teardown do
      Orchestration::ResourceTracker.for(@agent).reset!
    end

    def context_for(comment)
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

    def occupy_slot!(status: "running")
      Task.create!(
        name: "Holder", status: status, trigger_event_name: "comment_created",
        agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: { "topic" => { "id" => @topic.id } }
      )
    end

    test "queues a waiter instead of starting a second turn in an occupied topic" do
      occupy_slot!
      c = comment("late arrival")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued")
      assert_equal 1, waiters.count
      assert_equal c.id, waiters.first.trigger_event_payload.dig("comment", "id")
      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "running").count,
                   "the holder must remain the only running task"
    end

    # pending / pending_approval hold the slot too: pending is claimed but not
    # started, pending_approval is paused and does not drain the queue.
    test "treats a pending_approval holder as occupying the slot" do
      occupy_slot!(status: "pending_approval")
      c = comment("late arrival")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count
    end

    test "coalesces the late waiter with one already parked" do
      occupy_slot!
      first = comment("first")
      second = comment("second")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(first))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(second))

      waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued")
      assert_equal 1, waiters.count
      assert_equal second.id, waiters.first.trigger_event_payload.dig("comment", "id")
      assert_equal [ first.id ],
                   waiters.first.trigger_event_payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]
    end

    test "posts one waiting notice for the deferred burst" do
      occupy_slot!
      2.times { |i| AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("m#{i}"))) }

      notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
                       .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
      assert_equal 1, notices.count
    end

    test "runs normally when the topic slot is free" do
      c = comment("first in topic")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      assert_equal 0, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "an empty topic must not defer"
      assert Task.where(agent: @agent, topic_id: @topic.id).exists?,
             "a task should have been created and executed"
    end

    test "does not defer when the context carries no topic" do
      c = Comment.create!(creative: @creative, user: @user, content: "no topic", skip_dispatch: true)
      context = {
        "creative" => { "id" => @creative.id },
        "comment" => { "id" => c.id, "content" => c.content, "user_id" => @user.id }
      }

      AiAgentJob.new.perform(@agent.id, "comment_created", context)

      assert_equal 0, Task.where(agent: @agent, status: "queued").count
    end

    test "policy can disable the late slot check" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      c = comment("late arrival")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      assert_equal 0, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "with coalescing off the previous immediate behaviour returns"
    end
  end
end
