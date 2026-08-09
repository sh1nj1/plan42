# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class TaskCoalescerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @other_agent = Collavre::User.create!(
          name: "other-agent",
          email: "other-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4"
        )
        @topic = Collavre::Topic.create!(creative: @creative, name: "Coalesce topic", user: @user)
      end

      def create_waiter(comment_id:, agent: @agent, topic: @topic, creative: @creative,
                        status: "queued", event: "comment_created", merged: nil)
        payload = {
          "creative" => { "id" => creative&.id },
          "topic" => { "id" => topic&.id },
          "comment" => { "id" => comment_id, "content" => "msg #{comment_id}" }
        }
        payload[TaskCoalescer::PAYLOAD_KEY] = merged if merged

        Task.create!(
          name: "Response to #{event}",
          status: status,
          trigger_event_name: event,
          trigger_event_payload: payload,
          agent: agent,
          topic_id: topic&.id,
          creative_id: creative&.id
        )
      end

      test "absorbs older queued siblings into the newest waiter" do
        first = create_waiter(comment_id: 11)
        second = create_waiter(comment_id: 12)
        third = create_waiter(comment_id: 13)

        absorbed = TaskCoalescer.coalesce!(third)

        assert_equal [ first.id, second.id ].sort, absorbed.sort
        assert_equal "cancelled", first.reload.status
        assert_equal "cancelled", second.reload.status
        assert_equal "queued", third.reload.status
        assert_equal [ 11, 12 ], third.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]
      end

      test "keeps the newest comment as the trigger anchor" do
        create_waiter(comment_id: 11)
        newest = create_waiter(comment_id: 12)

        TaskCoalescer.coalesce!(newest)

        assert_equal 12, newest.reload.trigger_event_payload.dig("comment", "id")
      end

      test "merges ids a superseded task had already absorbed" do
        create_waiter(comment_id: 12, merged: [ 10, 11 ])
        newest = create_waiter(comment_id: 13)

        TaskCoalescer.coalesce!(newest)

        assert_equal [ 10, 11, 12 ], newest.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]
      end

      test "never lists the surviving anchor among the merged ids" do
        create_waiter(comment_id: 13)
        newest = create_waiter(comment_id: 13)

        TaskCoalescer.coalesce!(newest)

        assert_equal [], newest.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]
      end

      test "leaves tasks of other agents alone" do
        other = create_waiter(comment_id: 11, agent: @other_agent)
        mine = create_waiter(comment_id: 12)

        assert_empty TaskCoalescer.coalesce!(mine)
        assert_equal "queued", other.reload.status
      end

      test "leaves tasks of other topics alone" do
        other_topic = Collavre::Topic.create!(creative: @creative, name: "Elsewhere", user: @user)
        other = create_waiter(comment_id: 11, topic: other_topic)
        mine = create_waiter(comment_id: 12)

        assert_empty TaskCoalescer.coalesce!(mine)
        assert_equal "queued", other.reload.status
      end

      test "leaves tasks of other creatives alone" do
        other_creative = Creative.create!(description: "<p>Other</p>", user: @user, progress: 0.0)
        # Same topic on purpose: the creative dimension has to be what excludes it.
        other = create_waiter(comment_id: 11, creative: other_creative)
        mine = create_waiter(comment_id: 12)

        assert_empty TaskCoalescer.coalesce!(mine)
        assert_equal "queued", other.reload.status
      end

      test "leaves tasks triggered by a different event alone" do
        other = create_waiter(comment_id: 11, event: "creative_updated")
        mine = create_waiter(comment_id: 12)

        assert_empty TaskCoalescer.coalesce!(mine)
        assert_equal "queued", other.reload.status
      end

      # A pending task may already be riding an enqueued AiAgentJob. Cancelling
      # it makes that job return early without draining the topic queue, which
      # stalls the topic permanently.
      test "does not supersede pending or running tasks" do
        pending_task = create_waiter(comment_id: 11, status: "pending")
        running_task = create_waiter(comment_id: 12, status: "running")
        newest = create_waiter(comment_id: 13)

        assert_empty TaskCoalescer.coalesce!(newest)
        assert_equal "pending", pending_task.reload.status
        assert_equal "running", running_task.reload.status
      end

      # Two concurrent dispatches must not cancel each other: with :older each
      # run only supersedes strictly lower ids, so the newest always survives.
      test "older scope leaves a survivor when both siblings coalesce" do
        first = create_waiter(comment_id: 11)
        second = create_waiter(comment_id: 12)

        TaskCoalescer.coalesce!(second)
        TaskCoalescer.coalesce!(first)

        assert_equal "cancelled", first.reload.status
        assert_equal "queued", second.reload.status
      end

      # dequeue_next_for_topic promotes the OLDEST waiter, so the siblings left
      # behind it are newer and the :older id guard would absorb nothing.
      test "all scope absorbs newer siblings for a promoted task" do
        promoted = create_waiter(comment_id: 11, status: "pending")
        newer = create_waiter(comment_id: 12)

        absorbed = TaskCoalescer.coalesce!(promoted, scope: :all)

        assert_equal [ newer.id ], absorbed
        assert_equal "cancelled", newer.reload.status
        assert_equal [ 12 ], promoted.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]
      end

      # The survivor is read once by the caller and then trusted. Deleting its
      # anchor cancels it through Comment#cancel_pending_tasks, which holds no
      # lock this method waits on — so a fold running against a stale object
      # cancels every still-valid sibling and merges the whole burst onto a task
      # AiAgentJob abandons on sight. Nothing else is left to answer them.
      test "does not supersede siblings when the survivor is no longer un-started" do
        first = create_waiter(comment_id: 11)
        second = create_waiter(comment_id: 12)
        keep = create_waiter(comment_id: 13)
        Task.where(id: keep.id).update_all(status: "cancelled")

        assert_empty TaskCoalescer.coalesce!(keep)
        assert_equal "queued", first.reload.status
        assert_equal "queued", second.reload.status,
                     "a dead survivor must not take the burst down with it"
      end

      # Control: revalidating the survivor must not stop ordinary folds. The
      # promotion path hands over a `pending` task, which is un-started and
      # therefore still a valid survivor.
      test "still folds for a pending survivor" do
        newer = create_waiter(comment_id: 12)
        promoted = create_waiter(comment_id: 11, status: "pending")

        assert_equal [ newer.id ], TaskCoalescer.coalesce!(promoted, scope: :all)
        assert_equal "cancelled", newer.reload.status
      end

      test "records a superseded task action for each absorbed task" do
        first = create_waiter(comment_id: 11)
        newest = create_waiter(comment_id: 12)

        TaskCoalescer.coalesce!(newest)

        action = first.reload.task_actions.find_by(action_type: "superseded")
        assert_not_nil action
        assert_equal newest.id, action.payload["superseded_by_task_id"]
      end

      test "returns empty and leaves the payload untouched when there is nothing to absorb" do
        only = create_waiter(comment_id: 11)

        assert_empty TaskCoalescer.coalesce!(only)
        assert_nil only.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]
      end

      test "absorb_into_payload dedupes, sorts and excludes the anchor" do
        payload = {
          "comment" => { "id" => 5 },
          TaskCoalescer::PAYLOAD_KEY => [ 3, 1 ]
        }

        result = TaskCoalescer.absorb_into_payload(payload, [ 5, 3, 2 ])

        assert_equal [ 1, 2, 3 ], result[TaskCoalescer::PAYLOAD_KEY]
      end

      test "absorb_into_payload keeps ids when the payload has no anchor" do
        result = TaskCoalescer.absorb_into_payload({}, [ 2, 1 ])

        assert_equal [ 1, 2 ], result[TaskCoalescer::PAYLOAD_KEY]
      end

      test "re-anchoring onto another person's comment replaces the workspace principal" do
        other_user = users(:two)
        original = @creative.comments.create!(
          content: "first", user: @user, topic: @topic, skip_dispatch: true
        )
        replacement = @creative.comments.create!(
          content: "second", user: other_user, topic: @topic, skip_dispatch: true
        )
        payload = original.dispatch_payload.deep_stringify_keys.merge(
          "workspace_user_id" => @user.id
        )

        moved = TaskCoalescer.reanchor_payload(payload, replacement)

        assert_equal other_user.id, moved["workspace_user_id"]
      end

      test "re-anchoring an ordinary dispatch does not add a workspace principal" do
        other_user = users(:two)
        original = @creative.comments.create!(
          content: "first", user: @user, topic: @topic, skip_dispatch: true
        )
        replacement = @creative.comments.create!(
          content: "second", user: other_user, topic: @topic, skip_dispatch: true
        )

        moved = TaskCoalescer.reanchor_payload(
          original.dispatch_payload.deep_stringify_keys, replacement
        )

        assert_not moved.key?("workspace_user_id")
      end

      test "re-anchoring onto an AI comment clears an unprovable workspace principal" do
        original = @creative.comments.create!(
          content: "first", user: @user, topic: @topic, skip_dispatch: true
        )
        replacement = @creative.comments.create!(
          content: "second", user: @other_agent, topic: @topic, skip_dispatch: true
        )
        payload = original.dispatch_payload.deep_stringify_keys.merge(
          "workspace_user_id" => @user.id
        )

        moved = TaskCoalescer.reanchor_payload(payload, replacement)

        assert_not moved.key?("workspace_user_id")
      end

      test "a no-op re-anchor keeps the carried A2A workspace principal" do
        anchor = @creative.comments.create!(
          content: "A2A", user: @other_agent, topic: @topic, skip_dispatch: true
        )
        payload = anchor.dispatch_payload.deep_stringify_keys.merge(
          "workspace_user_id" => @user.id
        )

        unchanged = TaskCoalescer.reanchor_payload(payload, anchor)

        assert_equal @user.id, unchanged["workspace_user_id"]
      end
    end
  end
end
