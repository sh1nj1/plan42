# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class AgentOrchestratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @ai_agent = users(:ai_bot)
        @creative = creatives(:tshirt)

        # Ensure AI agent has permission (searchable) for tests
        @ai_agent.update!(searchable: true)

        # Grant feedback permission on the creative for AI agent
        # (searchable only affects discoverability, not response permission)
        share = CreativeShare.find_or_create_by!(creative: @creative, user: @ai_agent)
        share.update!(permission: "feedback")
        # Manually create cache entry (after_commit doesn't run in test transaction)
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id,
          user_id: @ai_agent.id,
          permission: :feedback
        )

        # Clear any existing routing expressions
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
      end

      test "dispatches to mentioned AI agent" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        # Verify the returned agents (jobs run inline in test)
        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent
      end

      test "does not dispatch when human is mentioned" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => {
            "content" => "@#{@user.name}: hello",
            "mentioned_user" => { "id" => @user.id }
          },
          "comment" => { "content" => "@#{@user.name}: hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_empty result
      end

      test "dispatches to agents matching routing expression" do
        @ai_agent.update!(routing_expression: 'event_name == "comment_created"')

        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent
      end

      test "does not dispatch when routing expression does not match" do
        @ai_agent.update!(routing_expression: 'event_name == "other_event"')

        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_not_includes result, @ai_agent
      end

      test "returns empty array when no agents match" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_empty result
      end

      test "selects agents after arbitration without scheduling" do
        other_agent = User.create!(
          email: "dispatcher_other_agent@example.com",
          name: "Dispatcher Other Agent",
          password: "password",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash",
          searchable: true
        )
        context = { "creative" => { "id" => @creative.id } }
        selected_agent = @ai_agent
        matcher = Object.new
        matcher.define_singleton_method(:match) { [ selected_agent, other_agent ] }
        arbiter = Object.new
        arbiter.define_singleton_method(:select) { |_candidates, **| [ selected_agent ] }
        arbiter.define_singleton_method(:commit_selection!) { }
        Matcher.stub(:new, matcher) do
          Arbiter.stub(:new, arbiter) do
            assert_equal [ @ai_agent ], AgentOrchestrator.select("comment_created", context)
          end
        end
      end

      test "reports only scheduler-accepted agents before enqueue" do
        accepted = @ai_agent
        rejected = User.create!(
          email: "rejected_scheduled_agent@example.com", name: "Rejected Scheduled Agent",
          password: "password", llm_vendor: "google", llm_model: "gemini-1.5-flash"
        )
        scheduler = Object.new
        scheduler.define_singleton_method(:schedule) do |_agents, **_options|
          [
            { agent: accepted, timing: :immediate },
            { agent: rejected, timing: :rejected, reason: :quota_exceeded }
          ]
        end
        scheduled = nil

        Scheduler.stub(:new, scheduler) do
          hooks = SchedulingHooks.new(
            interaction_callback: nil, scheduled_callback: ->(agents) { scheduled = agents }
          )
          AgentOrchestrator.dispatch(
            "comment_created", { "creative" => { "id" => @creative.id } },
            selected_agents: [ accepted, rejected ], scheduling_hooks: hooks
          )
        end

        assert_equal [ accepted ], scheduled
      end

      # Deferred enqueue
      test "deferred decision creates queued task" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        # Create a running task to trigger topic concurrency limit
        Task.create!(name: "Running", status: "running", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)

        queued_count_before = Task.where(status: "queued", topic_id: topic.id).count
        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent

        queued_tasks = Task.where(status: "queued", topic_id: topic.id)
        assert_equal queued_count_before + 1, queued_tasks.count
        queued_task = queued_tasks.last
        assert_equal @ai_agent.id, queued_task.agent_id
        assert_equal topic.id, queued_task.topic_id
      end

      test "deferred decision creates no waiter after its topic moves" do
        topic = Topic.create!(name: "Moved deferred topic", creative: @creative, user: @user)
        destination = Creative.create!(description: "Deferred destination", user: @user)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "comment" => { "content" => "stale deferred dispatch" }
        }
        orchestrator = AgentOrchestrator.new(event_name: "comment_created", context: context)
        Topics::TopicMove.new(topic: topic, target_creative: destination).call

        assert_no_difference -> { Task.where(topic_id: topic.id).count } do
          assert_nil orchestrator.send(:park_waiter, @ai_agent, context)
        end
      end

      test "delayed enqueue survives a topic move before its waiting notice" do
        topic = Topic.create!(name: "Moved delayed topic", creative: @creative, user: @user)
        destination = Creative.create!(description: "Delayed destination", user: @user)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "comment" => { "content" => "stale delayed dispatch" }
        }
        orchestrator = AgentOrchestrator.new(event_name: "comment_created", context: context)
        queued_job = Object.new
        queued_job.define_singleton_method(:perform_later) do |*|
          Topics::TopicMove.new(topic: topic, target_creative: destination).call
        end

        result = nil
        assert_no_difference -> { Comment.where(topic_id: topic.id, user_id: nil).count } do
          AiAgentJob.stub(:set, ->(**) { queued_job }) do
            result = orchestrator.send(
              :enqueue_jobs,
              [ { agent: @ai_agent, timing: :delayed, delay: 1.minute, reason: :busy } ],
              context_for: nil
            )
          end
        end

        assert_equal [ @ai_agent ], result
        assert_equal destination, topic.reload.creative
      end

      # The "⏳" waiting notice must name the agent holding the running slot, so a
      # waiting user sees *who* is blocking them (and can reach that task's stop
      # button) instead of an anonymous "another task is running" dead end.
      test "deferred topic-concurrency notice names the running blocker agent" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        # A running task on the same topic forces the topic-concurrency defer.
        Task.create!(name: "Running", status: "running", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)

        AgentOrchestrator.dispatch("comment_created", context)

        notice = @creative.comments.where(topic_id: topic.id)
                          .find { |c| c.content.include?("⏳") }
        assert notice, "expected a ⏳ waiting notice comment"
        assert_includes notice.content, "@#{@ai_agent.name}",
                        "waiting notice should name the running blocker agent"
      end

      # "One notice per topic" only holds if the existence check and the insert
      # are one step. The burst this path handles is exactly what breaks a
      # read-then-write: every deferring worker reads "no notice yet" before any
      # of them inserts, and the topic collects N dead ends for one blocker.
      test "the late-defer notice checks and inserts under the admission lock" do
        topic = Topic.create!(name: "Notice lock topic", creative: @creative, user: @user)
        # A notice describes a waiter; the same lock also decides whether one is
        # still waiting, so the queue has to be non-empty for the insert to run.
        Task.create!(name: "Waiter", status: "queued", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)
        locked_topic_ids = []
        lock_relation = Struct.new(:sink) do
          def find_by(id:)
            sink << id
            nil
          end
        end.new(locked_topic_ids)

        baseline_depth = Comment.connection.open_transactions
        check_depth = nil

        Topic.stub(:lock, lock_relation) do
          AgentOrchestrator.stub(:topic_concurrency_notice_exists?, ->(*) {
            check_depth ||= Comment.connection.open_transactions
            false
          }) do
            AgentOrchestrator.post_topic_concurrency_notice(@creative.id, topic.id)
          end
        end

        assert_equal [ topic.id ], locked_topic_ids.uniq,
                     "the notice must serialize on the same row admission locks"
        assert_operator check_depth, :>, baseline_depth,
                        "the existence check must run inside the inserting transaction"
      end

      test "a second late-defer for the same topic adds no second notice" do
        topic = Topic.create!(name: "Notice dedup topic", creative: @creative, user: @user)
        Task.create!(name: "Running", status: "running", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)
        Task.create!(name: "Waiter", status: "queued", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)

        2.times { AgentOrchestrator.post_topic_concurrency_notice(@creative.id, topic.id) }

        notices = @creative.comments.where(topic_id: topic.id, topic_concurrency_defer: true)
                           .select { |c| c.content.start_with?(Comment::WAITING_NOTICE_PREFIX) }
        assert_equal 1, notices.size, "one waiting notice per topic, not one per deferral"
      end

      # The waiting notice must expose a stop button for the *blocker* so a user
      # can cancel a hung in-progress task and unstick their deferred waiter.
      # The button targets the running blocker resolved at render time, NOT the
      # notice's own task_id (which would collide with Task#reply_comment).
      test "deferred topic-concurrency notice exposes the running blocker as its stop target" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        blocker = Task.create!(name: "Running", status: "running", trigger_event_name: "e",
                               agent: @ai_agent, topic_id: topic.id, creative: @creative)

        AgentOrchestrator.dispatch("comment_created", context)

        notice = @creative.comments.where(topic_id: topic.id)
                          .find { |c| c.content.include?("⏳") }
        assert notice, "expected a ⏳ waiting notice comment"
        assert notice.waiting_notice?, "system notice should be flagged as a waiting notice"
        assert_nil notice.task_id,
                   "notice must not borrow task_id (would shadow the blocker's reply_comment)"
        assert_equal blocker.id, notice.topic_blocking_task&.id,
                     "stop button must target the running blocker task"
      end

      # A :delayed (busy / rate_limited) notice reuses the same "⏳" content but
      # does NOT queue a topic waiter; cancelling some unrelated running task in
      # the topic would not unblock it, so no blocker stop button must be shown.
      test "non-concurrency waiting notice exposes no blocker stop target" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        # A running task exists in the topic, but there is NO queued waiter —
        # this notice is a delayed (rate_limited) one, not a concurrency defer.
        Task.create!(name: "Unrelated running", status: "running", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)
        notice = @creative.comments.create!(
          content: "⏳ rate limited, retrying soon", topic_id: topic.id,
          private: false, skip_default_user: true
        )

        assert notice.waiting_notice?, "system notice should be flagged as a waiting notice"
        assert_nil notice.topic_blocking_task,
                   "delayed notice (no queued waiter) must not surface a blocker stop button"
      end

      # A blocker paused on pending_approval still occupies the topic slot and is
      # cancellable, so the waiting notice must keep showing its stop button.
      test "waiting notice resolves a pending_approval blocker as its stop target" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        blocker = Task.create!(name: "Approval-paused", status: "pending_approval",
                               trigger_event_name: "e", agent: @ai_agent,
                               topic_id: topic.id, creative: @creative)
        Task.create!(name: "Queued waiter", status: "queued", trigger_event_name: "comment_created",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)
        notice = @creative.comments.create!(
          content: "⏳ waiting on the topic", topic_id: topic.id,
          private: false, skip_default_user: true, topic_concurrency_defer: true
        )

        assert_equal blocker.id, notice.topic_blocking_task&.id,
                     "stop button must target the pending_approval slot holder"
      end

      # Codex P2: gating the button on "any queued task in the topic" leaks — a
      # :delayed (rate_limited) notice posted in a topic that already has an
      # unrelated concurrency waiter would expose a stop button for a blocker
      # whose cancellation does not unblock the delayed job. topic_concurrency_defer
      # (set only on the :deferred path) is the per-notice discriminator.
      test "delayed notice shows no blocker button even when an unrelated queued waiter exists" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        # Occupied slot + a genuine concurrency waiter for some OTHER agent.
        Task.create!(name: "Running blocker", status: "running", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)
        Task.create!(name: "Unrelated queued waiter", status: "queued",
                     trigger_event_name: "comment_created",
                     agent: @ai_agent, topic_id: topic.id, creative: @creative)
        # This notice is a :delayed (busy / rate_limited) one — NOT a concurrency defer.
        delayed_notice = @creative.comments.create!(
          content: "⏳ rate limited, retrying soon", topic_id: topic.id,
          private: false, skip_default_user: true, topic_concurrency_defer: false
        )

        assert_nil delayed_notice.topic_blocking_task,
                   "a :delayed notice must not borrow another waiter's blocker button"
      end

      # dequeue_next_for_topic
      test "dequeue_next_for_topic claims queued task as pending" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          agent: @ai_agent, topic_id: topic.id
        )

        # dequeue_next_for_topic atomically claims the task as "pending"
        # (inline adapter will run the job immediately, changing status further,
        # so we verify via the atomic update count)
        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        # Task should no longer be "queued" — it was claimed and processed
        assert_not_equal "queued", queued_task.reload.status
      end

      test "dequeue_next_for_topic refreshes context with latest human comment" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        # Original trigger comment
        original_comment = Comment.create!(
          creative: @creative, user: @user, content: "1", topic: topic
        )

        # Queued task with stale context pointing to original comment
        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id },
            "comment" => { "id" => original_comment.id, "content" => "1" },
            "chat" => { "content" => "1" }
          },
          agent: @ai_agent, topic_id: topic.id
        )

        # Another human replied "2" after the task was queued
        latest_comment = Comment.create!(
          creative: @creative, user: @user, content: "2", topic: topic
        )

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        # Context should now point to the latest human comment
        refreshed = queued_task.reload.trigger_event_payload
        assert_equal latest_comment.id, refreshed.dig("comment", "id")
        assert_equal "2", refreshed.dig("comment", "content")
        assert_equal "2", refreshed.dig("chat", "content")
      end

      test "refresh keeps a per-user proxy turn on its original human workspace principal" do
        owner = @user
        gateway = AgentGateway.create!(
          owner: owner,
          name: "Principal-bound proxy",
          base_url: "https://proxy.example.com",
          admin_key: "admin",
          completion_key: "completion",
          identity_secret: "p" * 32,
          workspace_mode: :per_user
        )
        @ai_agent.update!(
          llm_vendor: "cli_proxy",
          llm_model: "paperclip/claude_local",
          creator: owner,
          agent_gateway: gateway
        )
        topic = Topic.create!(name: "Principal-bound topic", creative: @creative, user: @user)
        original_comment = Comment.create!(
          creative: @creative, user: @user, content: "from A", topic: topic
        )
        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id },
            "comment" => { "id" => original_comment.id, "content" => original_comment.content },
            "chat" => { "content" => original_comment.content }
          },
          agent: @ai_agent, topic_id: topic.id
        )
        other_user = users(:two)
        Comment.create!(creative: @creative, user: other_user, content: "from B", topic: topic)

        AgentOrchestrator.send(:refresh_deferred_context!, queued_task)

        refreshed = queued_task.reload.trigger_event_payload
        assert_equal original_comment.id, refreshed.dig("comment", "id")
        assert_equal "from A", refreshed.dig("comment", "content")
        assert_not_includes Array(refreshed[TaskCoalescer::PAYLOAD_KEY]), original_comment.id
      end

      test "refresh_deferred_context skips agent's own comments" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        human_comment = Comment.create!(
          creative: @creative, user: @user, content: "human msg", topic: topic
        )

        # AI agent replied after the human
        Comment.create!(
          creative: @creative, user: @ai_agent, content: "ai reply", topic: topic
        )

        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id },
            "comment" => { "id" => 0, "content" => "stale" },
            "chat" => { "content" => "stale" }
          },
          agent: @ai_agent, topic_id: topic.id
        )

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        # Should pick the human comment, not the AI's own reply
        refreshed = queued_task.reload.trigger_event_payload
        assert_equal human_comment.id, refreshed.dig("comment", "id")
        assert_equal "human msg", refreshed.dig("comment", "content")
      end

      test "refresh_deferred_context cancels task when no eligible comments remain" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        # Only AI agent's own comment exists
        Comment.create!(
          creative: @creative, user: @ai_agent, content: "ai only", topic: topic
        )

        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id },
            "comment" => { "id" => 0, "content" => "stale" },
            "chat" => { "content" => "stale" }
          },
          agent: @ai_agent, topic_id: topic.id
        )

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_equal "cancelled", queued_task.reload.status
      end

      test "dequeue_next_for_topic does nothing when no queued tasks" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        task_count_before = Task.count

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_equal task_count_before, Task.count
      end

      test "dequeue_next_for_topic does nothing with nil topic_id when no queued tasks" do
        task_count_before = Task.count

        AgentOrchestrator.dequeue_next_for_topic(nil)

        assert_equal task_count_before, Task.count
      end

      test "dequeue_next_for_topic processes queued main-topic tasks with nil topic_id" do
        queued_task = Task.create!(
          name: "Queued main-topic task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: { "creative" => { "id" => @creative.id }, "topic" => { "id" => nil } },
          agent: @ai_agent, topic_id: nil
        )

        AgentOrchestrator.dequeue_next_for_topic(nil)

        assert_not_equal "queued", queued_task.reload.status
      end

      # A queued waiter keeps the agent chosen at dispatch time, so an exclusive
      # assignment made while it waited has to be rechecked on promotion.
      test "dequeue_next_for_topic cancels a waiter the topic assignment now excludes" do
        topic = Topic.create!(name: "Assigned while waiting", creative: @creative, user: @user)
        other = build_agent
        Comment.create!(creative: @creative, user: @user, content: "please help", topic: topic)

        queued_task = queued_task_for(other, topic)
        topic.set_primary_agent!(@ai_agent)

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_equal "cancelled", queued_task.reload.status
      end

      test "dequeue_next_for_topic keeps a waiter that is the topic's primary agent" do
        topic = Topic.create!(name: "Assigned to the waiter", creative: @creative, user: @user)
        Comment.create!(creative: @creative, user: @user, content: "please help", topic: topic)

        queued_task = queued_task_for(@ai_agent, topic)
        topic.set_primary_agent!(@ai_agent)

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_not_equal "cancelled", queued_task.reload.status
      end

      # refresh_deferred_context! rewrites the whole "chat" hash, dropping the
      # resolved mentioned_user — so the revalidation has to rebuild the context
      # or an explicitly invited agent would be cancelled by an unrelated pin.
      test "dequeue_next_for_topic keeps a waiter the latest comment still mentions" do
        topic = Topic.create!(name: "Mentioned while waiting", creative: @creative, user: @user)
        other = build_agent
        Comment.create!(
          creative: @creative, user: @user, content: "@#{other.name}: your turn", topic: topic
        )

        queued_task = queued_task_for(other, topic)
        topic.set_primary_agent!(@ai_agent)

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_not_equal "cancelled", queued_task.reload.status
      end

      test "dequeue_next_for_topic drains to the next waiter after cancelling an excluded one" do
        topic = Topic.create!(name: "Drain past excluded", creative: @creative, user: @user)
        other = build_agent
        Comment.create!(creative: @creative, user: @user, content: "please help", topic: topic)

        excluded = queued_task_for(other, topic)
        successor = queued_task_for(@ai_agent, topic)
        topic.set_primary_agent!(@ai_agent)

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_equal "cancelled", excluded.reload.status
        assert_not_equal "queued", successor.reload.status,
                         "cancelling an excluded waiter must not strand the rest of the queue"
      end

      private

      def build_agent
        agent = User.create!(
          name: "Agent #{SecureRandom.hex(3)}",
          email: "agent_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true
        )
        share = CreativeShare.find_or_create_by!(creative: @creative, user: agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: agent.id, permission: :feedback
        )
        agent
      end

      def queued_task_for(agent, topic)
        Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id },
            "comment" => { "id" => 0, "content" => "stale" },
            "chat" => { "content" => "stale" }
          },
          agent: agent, topic_id: topic.id
        )
      end
    end
  end
end
