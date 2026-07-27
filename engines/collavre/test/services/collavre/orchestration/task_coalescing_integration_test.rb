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

      def dispatch_comment(body, user: @user)
        comment = Comment.create!(
          creative: @creative, user: user, topic: @topic, content: body, skip_dispatch: true
        )
        AgentOrchestrator.dispatch("comment_created", {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => user.id, "name" => user.name },
          "chat" => { "content" => body },
          "comment" => { "id" => comment.id, "content" => body, "user_id" => user.id }
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

      # Coalescing makes one task carry several comments, so cancelling it when
      # its anchor is deleted would discard the absorbed ones as well — and they
      # have no task of their own left to fall back to.
      test "deleting a coalesced waiter's anchor re-anchors instead of dropping the turn" do
        block_topic!
        first = dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")
        third = dispatch_comment("@#{@agent.name}: third")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        assert_equal third.id, waiter.trigger_event_payload.dig("comment", "id")

        third.destroy!

        waiter.reload
        assert_equal "queued", waiter.status,
                     "the turn still has the first two comments to answer"
        payload = waiter.trigger_event_payload
        assert_equal second.id, payload.dig("comment", "id"),
                     "the newest surviving absorbed comment becomes the anchor"
        assert_equal second.content, payload.dig("chat", "content")
        assert_equal [ first.id ], payload[TaskCoalescer::PAYLOAD_KEY]
      end

      # Re-anchoring picks the newest absorbed comment by id alone. A comment
      # moved to another creative while the task waited is no longer part of this
      # turn, but it was still eligible — so the waiter would adopt an anchor
      # outside its own creative and the reply would be written there, into a
      # creative the agent may have no share on.
      test "re-anchoring skips absorbed comments moved out of the creative" do
        block_topic!
        first = dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")
        third = dispatch_comment("@#{@agent.name}: third")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        elsewhere = Creative.create!(description: "Elsewhere", user: @user)
        second.update!(creative: elsewhere, topic_id: nil)

        third.destroy!

        payload = waiter.reload.trigger_event_payload
        assert_equal first.id, payload.dig("comment", "id"),
                     "the moved comment is out of scope; fall back to one still in the creative"
        refute_includes Array(payload[TaskCoalescer::PAYLOAD_KEY]), second.id,
                        "a comment in another creative must not stay merged into this turn"
      end

      # The task's scope is the task's own, not the deleted comment's. cancel_
      # pending_tasks looks tasks up without any creative scoping precisely
      # because CommentMoveService can move a comment without touching the task
      # it triggered — so a moved-then-deleted anchor searched for replacements
      # in the creative it was moved *to*, found none, and cancelled a turn whose
      # absorbed comments were all still sitting in the original creative.
      test "re-anchoring searches the task's creative, not the moved anchor's" do
        block_topic!
        first = dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")
        third = dispatch_comment("@#{@agent.name}: third")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        elsewhere = Creative.create!(description: "Elsewhere", user: @user)
        third.update!(creative: elsewhere, topic_id: nil)

        third.destroy!

        waiter.reload
        assert_equal "queued", waiter.status,
                     "the absorbed comments are still in this creative and still unanswered"
        payload = waiter.trigger_event_payload
        assert_equal second.id, payload.dig("comment", "id")
        assert_equal [ first.id ], payload[TaskCoalescer::PAYLOAD_KEY]
      end

      # cancel_pending_tasks hands reanchor_coalesced_task the task object its own
      # scan loaded, and the callback derives the replacement payload from that
      # snapshot without ever locking the row. TaskCoalescer folds a sibling into
      # the same task under a lock this path does not take, so the fold can commit
      # inside that window and the re-anchor writes the pre-fold payload back over
      # it. The absorbed sibling is cancelled by then, so its comment has no task
      # left to answer it — here the whole turn is cancelled instead, because the
      # snapshot's merged list is empty.
      test "re-anchoring reads the payload the coalescer left, not the caller's snapshot" do
        block_topic!
        anchor = dispatch_comment("@#{@agent.name}: anchor")
        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        snapshot = Task.find(waiter.id)

        late = Comment.create!(
          creative: @creative, user: @user, topic: @topic,
          content: "@#{@agent.name}: late", skip_dispatch: true
        )
        sibling = queued_waiter_for(late)
        TaskCoalescer.coalesce!(waiter, scope: :all)
        assert_equal "cancelled", sibling.reload.status,
                     "premise: the fold cancelled the late comment's own waiter"
        assert_includes waiter.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY], late.id

        assert anchor.send(:reanchor_coalesced_task, snapshot),
               "the folded comment is still unanswered work — the turn must survive"

        payload = waiter.reload.trigger_event_payload
        assert_equal late.id, payload.dig("comment", "id"),
                     "the comment the fold merged in becomes the anchor"
      end

      # The same window can flip the task's status: the caller's snapshot says
      # `queued` while promotion has already claimed it and AiAgentJob has handed
      # it its payload. Re-anchoring a started turn silently re-targets work the
      # agent is already doing; deleting the prompt has to stop it instead.
      test "re-anchoring revalidates the status against the locked row" do
        block_topic!
        first = dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        assert_equal second.id, waiter.trigger_event_payload.dig("comment", "id")
        snapshot = Task.find(waiter.id)
        Task.where(id: waiter.id).update_all(status: "running")

        assert_not second.send(:reanchor_coalesced_task, snapshot),
                   "a turn that has already started is not ours to re-target"
        assert_equal second.id, waiter.reload.trigger_event_payload.dig("comment", "id")
        assert_includes waiter.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY], first.id
      end

      # With coalescing off, post_waiting_notice deliberately skips the dedup path
      # and posts one notice per deferral — so a notice stands for exactly one
      # waiter, and cancelling every queued task lets a user discard unrelated
      # waiters by dismissing a single notice.
      test "with coalescing off, deleting one notice cancels only its own waiter" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "coalesce_pending_tasks" => false }
        )
        block_topic!

        3.times { |i| dispatch_comment("@#{@agent.name}: msg #{i}") }

        notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                                topic_concurrency_defer: true)
                         .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
                         .order(:id).to_a
        assert_equal 3, notices.size, "premise: the opt-out posts one notice per deferral"
        assert_equal 3, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count

        notices.last.destroy!

        assert_equal 2, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                     "a notice that was never deduplicated speaks for one waiter only"
      end

      test "deleting the anchor still cancels a waiter with nothing absorbed" do
        block_topic!
        only = dispatch_comment("@#{@agent.name}: only")
        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole

        only.destroy!

        assert_equal "cancelled", waiter.reload.status
      end

      # A running task has already been handed its payload: deleting the prompt
      # must still stop the turn rather than silently re-target it.
      test "deleting the anchor of a running coalesced task still cancels it" do
        first = dispatch_comment("@#{@agent.name}: first")
        second = Comment.create!(
          creative: @creative, user: @user, topic: @topic,
          content: "@#{@agent.name}: second", skip_dispatch: true
        )
        task = Task.create!(
          name: "In flight", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => @topic.id },
            "comment" => { "id" => second.id, "content" => second.content },
            TaskCoalescer::PAYLOAD_KEY => [ first.id ]
          }
        )

        second.destroy!

        assert_equal "cancelled", task.reload.status
      end

      # Both doors onto the anchor replace "comment" but the payload also carries
      # a "sender" block, and SystemEvents::ContextBuilder only fills it in with
      # `||=` — it is never rebuilt on a promotion path. A stale sender labels the
      # new anchor's text with the wrong speaker in MessageBuilder and ships the
      # wrong author_id/author_name over ClaudeChannelAdapter.
      test "deleting the anchor rebuilds the sender from the surviving comment" do
        block_topic!
        other = users(:two)
        first = dispatch_comment("@#{@agent.name}: from other", user: other)
        second = dispatch_comment("@#{@agent.name}: from one")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        assert_equal @user.id, waiter.trigger_event_payload.dig("sender", "id")

        second.destroy!

        payload = waiter.reload.trigger_event_payload
        assert_equal first.id, payload.dig("comment", "id")
        assert_equal other.id, payload.dig("sender", "id"),
                     "the turn now answers #{other.name}'s comment and must say so"
        assert_equal expected_sender_for(other), payload["sender"],
                     "the rebuilt sender must carry the same shape the builder does — " \
                     "a two-key stub silently flips the is_a2a gate"
      end

      test "refresh rebuilds the sender when it moves onto another user's comment" do
        other = users(:two)
        stale = dispatch_comment("@#{@agent.name}: stale")
        task = queued_waiter_for(stale)
        task.update!(trigger_event_payload: task.trigger_event_payload.merge(
          "sender" => expected_sender_for(@user)
        ))
        newer = Comment.create!(
          creative: @creative, user: other, topic: @topic,
          content: "@#{@agent.name}: newer", skip_dispatch: true
        )

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        payload = task.reload.trigger_event_payload
        assert_equal newer.id, payload.dig("comment", "id")
        assert_equal expected_sender_for(other), payload["sender"],
                     "refreshing onto another user's comment must move the sender with it"
      end

      # Control: the rebuild must not fire blind. Re-anchoring within one user's
      # own burst leaves the sender exactly as it was.
      test "re-anchoring inside one user's burst leaves the sender untouched" do
        block_topic!
        dispatch_comment("@#{@agent.name}: first")
        second = dispatch_comment("@#{@agent.name}: second")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        before = waiter.trigger_event_payload["sender"]

        second.destroy!

        assert_equal before, waiter.reload.trigger_event_payload["sender"]
      end

      # TaskCoalescer supersedes by `id < keep.id`, which only means "everything
      # already parked" while id order and commit order agree. An unserialized
      # insert breaks that: the higher-id waiter can commit and fold first,
      # seeing nothing, and the lower-id one then folds nothing either because
      # the survivor is newer than its guard allows. AiAgentJob#admit_or_defer!
      # already creates its waiter under the topic lock; this door must too.
      test "a deferred dispatch creates and folds its waiter inside one locked transaction" do
        block_topic!
        dispatch_comment("@#{@agent.name}: first")

        baseline_depth = Task.connection.open_transactions
        locked = []
        locked_before_fold = nil
        fold_depth = nil

        TopicSlot.stub(:lock!, ->(topic_id, _creative_id = nil) { locked << topic_id; nil }) do
          TaskCoalescer.stub(:coalesce!, ->(_task, **_opts) {
            locked_before_fold ||= locked.dup
            fold_depth ||= Task.connection.open_transactions
            []
          }) do
            dispatch_comment("@#{@agent.name}: second")
          end
        end

        assert_equal [ @topic.id ], Array(locked_before_fold).uniq,
                     "the waiter must be created under the topic lock before folding"
        assert_operator fold_depth, :>, baseline_depth,
                        "creating the waiter and folding its siblings must be one transaction"
      end

      # Control: serializing the door must not change what it produces. A burst
      # arriving through the normal (unstubbed) path still collapses to one
      # waiter carrying the others.
      test "serializing the deferred door still folds an ordinary burst" do
        block_topic!
        first = dispatch_comment("@#{@agent.name}: alpha")
        second = dispatch_comment("@#{@agent.name}: beta")

        waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
        assert_equal second.id, waiter.trigger_event_payload.dig("comment", "id")
        assert_equal [ first.id ], waiter.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]
      end

      def expected_sender_for(user)
        SystemEvents::ContextBuilder.new(
          "comment" => { "user_id" => user.id }
        ).build["sender"]
      end
    end
  end
end
