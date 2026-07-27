# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # A burst of comments (a PR comment sync, a webhook batch) must produce one
    # agent turn per burst, not one per comment — and must not lose the content
    # of the comments it folds together.
    class TaskCoalescingIntegrationTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @agent.update!(searchable: true, routing_expression: "true")

        share = CreativeShare.find_or_create_by!(creative: @creative, user: @agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: @agent.id, permission: :feedback
        )

        @topic = Topic.create!(name: "Burst topic", creative: @creative, user: @user)
        ResourceTracker.for(@agent).reset!
      end

      teardown do
        ResourceTracker.for(@agent).reset!
      end

      # Occupy the topic's only concurrency slot so every dispatch defers.
      def block_topic!
        Task.create!(
          name: "Holder", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id
        )
      end

      def dispatch_comment(body)
        comment = Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: body, skip_dispatch: true
        )
        AgentOrchestrator.dispatch("comment_created", {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => @user.id, "name" => @user.name },
          "chat" => { "content" => body },
          "comment" => { "id" => comment.id, "content" => body, "user_id" => @user.id }
        })
        comment
      end

      def queued_waiter_for(comment)
        Task.create!(
          name: "Waiter", status: "queued", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => @topic.id },
            "comment" => { "id" => comment.id, "content" => comment.content },
            "chat" => { "content" => comment.content }
          }
        )
      end

      test "a burst of deferred comments leaves exactly one queued waiter" do
        block_topic!

        first = dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")
        third = dispatch_comment("@#{@agent.name}: third")

        waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued")
        assert_equal 1, waiters.count, "burst should collapse into a single waiter"

        waiter = waiters.first
        assert_equal third.id, waiter.trigger_event_payload.dig("comment", "id"),
                     "the newest comment stays the reply anchor"
        assert_equal [ first.id, second.id ].sort,
                     waiter.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY],
                     "superseded comments are merged, not dropped"
      end

      test "a burst posts exactly one waiting notice" do
        block_topic!

        3.times { |i| dispatch_comment("@#{@agent.name}: msg #{i}") }

        notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
                         .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
        assert_equal 1, notices.count,
                     "N notices would be N dead ends pointing at one blocker"
      end

      test "coalescing can be disabled by policy" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "coalesce_pending_tasks" => false }
        )
        block_topic!

        3.times { |i| dispatch_comment("@#{@agent.name}: msg #{i}") }

        assert_equal 3, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                     "policy off restores one waiter per comment"
      end

      # dequeue promotes the OLDEST waiter, so anything that raced past
      # enqueue-time coalescing sits BEHIND it. Without the :all-scope pass on
      # promotion those stragglers each get promoted in turn and — because
      # refresh_deferred_context! points every one of them at the same latest
      # comment — answer it again.
      test "promotion absorbs waiters queued behind it instead of replaying them" do
        first = dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")

        older = queued_waiter_for(first)
        newer = queued_waiter_for(second)
        assert_operator older.id, :<, newer.id

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "cancelled", newer.reload.status
        assert_equal 0, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                     "no waiter may be left behind to replay the same comment"
        assert_includes older.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY], first.id,
                        "the absorbed waiter's comment must reach the surviving turn"
      end

      test "refresh keeps the previous anchor when it moves to a newer comment" do
        stale = dispatch_comment("@#{@agent.name}: stale")
        task = Task.create!(
          name: "Waiter", status: "queued", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => @topic.id },
            "comment" => { "id" => stale.id, "content" => "stale" },
            "chat" => { "content" => "stale" }
          }
        )
        newer = Comment.create!(
          creative: @creative, user: @user, topic: @topic,
          content: "@#{@agent.name}: newer", skip_dispatch: true
        )

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        payload = task.reload.trigger_event_payload
        assert_equal newer.id, payload.dig("comment", "id")
        assert_includes payload[TaskCoalescer::PAYLOAD_KEY], stale.id,
                        "a replaced anchor must survive as a merged comment — a " \
                        "session agent only ever sees the trigger"
      end
    end
  end
end
