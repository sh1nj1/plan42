# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class TaskResumerTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @user = users(:one)
        @agent = users(:ai_bot)
        @creative = Creative.create!(description: "Resumable work", user: @user)
        @topic = @creative.topics.create!(name: "Resume topic", user: @user)
        @trigger = comment("Please summarize")
      end

      teardown { ActiveJob::Base.queue_adapter = @original_adapter }

      def comment(body, user: @user)
        @creative.comments.create!(user: user, topic: @topic, content: body, skip_dispatch: true)
      end

      def payload_for(comment)
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => @user.id, "name" => @user.name },
          "comment" => { "id" => comment.id, "content" => comment.content, "user_id" => @user.id }
        }
      end

      def task_for(status:, agent: @agent, trigger: @trigger, **attributes)
        Task.create!(
          name: "Turn", status: status, trigger_event_name: "comment_created", agent: agent,
          topic_id: @topic.id, creative_id: @creative.id, trigger_event_payload: payload_for(trigger),
          **attributes
        )
      end

      def notices
        @creative.comments.where(topic_id: @topic.id, user_id: nil).order(:id)
      end

      # Ids of the comments re-rendered over Turbo while the block runs.
      def rerendered_comment_ids
        ids = []
        Comment.alias_method :__original_broadcast_replace_to, :broadcast_replace_to
        Comment.define_method(:broadcast_replace_to) { |*| ids << id }
        yield
        ids
      ensure
        Comment.alias_method :broadcast_replace_to, :__original_broadcast_replace_to
        Comment.remove_method :__original_broadcast_replace_to
      end

      def channel_agent
        users(:channel_bot).tap { |agent| agent.update!(llm_model: "claude-code") }
      end

      # --- suspend! -----------------------------------------------------------

      test "suspend! sets a running turn aside and gives back its slot" do
        task = task_for(status: "running")
        tracker = ResourceTracker.for(@agent)
        tracker.reserve!(task.id)

        assert_equal :suspended, TaskResumer.suspend!(task, reason: :server_restart)

        task.reload
        assert_equal "suspended", task.status
        assert_equal "server_restart", task.suspend_reason
        assert_equal "running", task.suspended_from
        assert_not_nil task.suspended_at
        assert_nil task.resume_not_before
        assert_equal 0, tracker.active_jobs
        assert_equal "server_restart", task.trigger_event_payload.dig(ResumeContext::KEY, "reason")
        assert_equal @trigger.id, task.trigger_event_payload.dig(ResumeContext::KEY, "trigger_comment_id")
        assert_equal I18n.t("collavre.orchestration.suspension.suspended.server_restart", agent: @agent.display_name),
                     notices.last.content
      end

      test "suspend! promotes the waiter queued behind the suspended turn" do
        holder = task_for(status: "running")
        waiter = task_for(status: "queued", agent: users(:two), trigger: comment("Another request"))
        OrchestratorPolicy.create!(policy_type: "scheduling", scope_type: nil,
                                   config: { "topic_max_concurrent_jobs" => 1 })

        TaskResumer.suspend!(holder, reason: :agent_offline)

        assert_equal "pending", waiter.reload.status
        assert_enqueued_with(job: AiAgentJob, args: [ waiter ])
      end

      test "suspend! keeps a streamed partial reply visible but detaches it from the turn" do
        task = task_for(status: "running")
        partial = @creative.comments.create!(user: @agent, topic: @topic, content: "Half an answer",
                                             task: task, skip_dispatch: true)
        task.task_actions.create!(action_type: "start", status: "done")
        task.task_actions.create!(action_type: "reply_created", status: "done")

        TaskResumer.suspend!(task, reason: :server_restart)

        context = task.reload.trigger_event_payload[ResumeContext::KEY]
        assert_equal "Half an answer", context["partial_reply"]
        assert_equal [ "reply_created (done)" ], context["actions"]
        assert_nil partial.reload.task_id
        assert_nil task.reply_comment
      end

      test "suspend! removes a reply that never got past its placeholder" do
        task = task_for(status: "running")
        placeholder = @creative.comments.create!(user: @agent, topic: @topic, task: task, skip_dispatch: true,
                                                 content: Comment::STREAMING_PLACEHOLDER_CONTENT)

        TaskResumer.suspend!(task, reason: :server_restart)

        assert_not Comment.exists?(placeholder.id)
        assert_nil task.reload.trigger_event_payload.dig(ResumeContext::KEY, "partial_reply")
      end

      test "suspend! still suspends when the partial reply cannot be detached" do
        task = task_for(status: "running")
        stuck_reply = Object.new
        stuck_reply.define_singleton_method(:content) { "Partial" }
        stuck_reply.define_singleton_method(:update_column) { |*| raise ActiveRecord::StatementInvalid, "locked" }

        task.stub(:reply_comment, stuck_reply) do
          assert_equal :suspended, TaskResumer.suspend!(task, reason: :server_restart)
        end
        assert_equal "suspended", task.reload.status
        assert_equal "Partial", task.trigger_event_payload.dig(ResumeContext::KEY, "partial_reply")
      end

      test "suspend! of a waiter does not release a slot it never held" do
        waiter = task_for(status: "queued")
        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("other-task")

        assert_equal :suspended, TaskResumer.suspend!(waiter, reason: :agent_offline)

        assert_equal "queued", waiter.reload.suspended_from
        assert_equal 1, tracker.active_jobs
      end

      test "suspend! declines a turn that has already ended or waits on approval" do
        %w[done cancelled failed escalated pending_approval].each do |status|
          task = task_for(status: status)
          assert_nil TaskResumer.suspend!(task, reason: :server_restart), status
          assert_equal status, task.reload.status
        end
        assert_empty notices
      end

      test "suspend! rejects an unknown reason" do
        assert_raises(ArgumentError) { TaskResumer.suspend!(task_for(status: "running"), reason: :bored) }
      end

      test "suspend! with a reset time schedules the resume and names the time" do
        task = task_for(status: "running")
        reset_at = 2.hours.from_now.change(usec: 0)

        assert_enqueued_with(job: ResumeSuspendedTasksJob, args: [ { task_id: task.id } ], at: reset_at) do
          TaskResumer.suspend!(task, reason: :quota, resume_not_before: reset_at)
        end

        assert_equal reset_at, task.reload.resume_not_before
        assert_equal I18n.t("collavre.orchestration.suspension.suspended.quota_until",
                            agent: @agent.display_name, time: reset_at.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")),
                     notices.last.content
      end

      test "suspend! for quota without a reset time uses the open-ended notice" do
        TaskResumer.suspend!(task_for(status: "running"), reason: :quota)

        assert_equal I18n.t("collavre.orchestration.suspension.suspended.quota", agent: @agent.display_name),
                     notices.last.content
      end

      test "suspend! survives a resume job that cannot be scheduled" do
        task = task_for(status: "running")
        ResumeSuspendedTasksJob.stub(:set, ->(**) { raise ActiveJob::EnqueueError, "queue down" }) do
          assert_equal :suspended, TaskResumer.suspend!(task, reason: :quota, resume_not_before: 1.hour.from_now)
        end
        assert_equal "suspended", task.reload.status
      end

      test "suspending again reschedules without restarting the wait" do
        task = task_for(status: "running")
        first_reset = 1.hour.from_now.change(usec: 0)
        TaskResumer.suspend!(task, reason: :quota, resume_not_before: first_reset)
        suspended_at = task.reload.suspended_at

        travel 10.minutes do
          assert_no_difference -> { notices.count } do
            TaskResumer.suspend!(task, reason: :quota, resume_not_before: first_reset)
          end

          later_reset = 3.hours.from_now.change(usec: 0)
          assert_difference -> { notices.count }, 1 do
            TaskResumer.suspend!(task, reason: :quota, resume_not_before: later_reset)
          end

          task.reload
          assert_equal later_reset, task.resume_not_before
          assert_equal suspended_at, task.suspended_at
          assert_equal "running", task.suspended_from
        end
      end

      test "suspend! escalates a turn that has been resumed too often" do
        task = task_for(status: "running", resume_count: TaskResumer::MAX_RESUMES)
        placeholder = @creative.comments.create!(user: @agent, topic: @topic, task: task, skip_dispatch: true,
                                                 content: Comment::STREAMING_PLACEHOLDER_CONTENT)

        assert_equal :escalated, TaskResumer.suspend!(task, reason: :server_restart)

        assert_equal "escalated", task.reload.status
        assert_not Comment.exists?(placeholder.id)
        assert_equal I18n.t("collavre.orchestration.suspension.escalated",
                            agent: @agent.display_name,
                            cause: I18n.t("collavre.orchestration.suspension.escalation_causes.too_many_resumes")),
                     notices.last.content
      end

      test "the suspension notice carries the turn's Stop control while it is suspended" do
        task = task_for(status: "running")
        TaskResumer.suspend!(task, reason: :server_restart)
        notice = notices.last

        assert_equal task, Comment::SuspensionNotice.turn_for(notice)
        html = ApplicationController.render(partial: "collavre/comments/comment", locals: { comment: notice })
        assert Nokogiri::HTML.fragment(html).at_css(".comment-stop-btn[data-task-id='#{task.id}']")

        refreshed = rerendered_comment_ids { assert_equal :resumed, TaskResumer.resume!(task.reload) }

        assert_includes refreshed, notice.id
        assert_nil Comment::SuspensionNotice.turn_for(notice.reload)
        html = ApplicationController.render(partial: "collavre/comments/comment", locals: { comment: Comment.find(notice.id) })
        assert_nil Nokogiri::HTML.fragment(html).at_css(".comment-stop-btn")
      end

      test "ending a suspended turn refreshes its suspension notice" do
        task = task_for(status: "running")
        TaskResumer.suspend!(task, reason: :server_restart)
        notice = notices.last

        assert_equal [ notice.id ], rerendered_comment_ids { task.reload.cancel_if_active! }
      end

      test "suspension notices do not dispatch to agents" do
        task = task_for(status: "running")
        @topic.update!(primary_agent: @agent)
        assert_no_enqueued_jobs(only: AiAgentJob) { TaskResumer.suspend!(task, reason: :server_restart) }
        assert_equal 1, notices.count
      end

      test "a notice that cannot be posted does not undo the suspension" do
        task = task_for(status: "running")
        Creative.stub(:find_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db gone" }) do
          assert_equal :suspended, TaskResumer.suspend!(task, reason: :server_restart)
        end
        assert_equal "suspended", task.reload.status
        assert_empty notices
      end

      # --- resume! ------------------------------------------------------------

      test "resume! re-queues the same row and promotes it into the free slot" do
        task = task_for(status: "running")
        TaskResumer.suspend!(task, reason: :server_restart)

        assert_equal :resumed, TaskResumer.resume!(task)

        task.reload
        assert_equal "pending", task.status
        assert_equal 1, task.resume_count
        assert_enqueued_with(job: AiAgentJob, args: [ task ])
        assert_equal I18n.t("collavre.orchestration.suspension.resumed", agent: @agent.display_name),
                     notices.last.content
      end

      test "resume! waits in the queue while the topic slot is taken" do
        OrchestratorPolicy.create!(policy_type: "scheduling", scope_type: nil,
                                   config: { "topic_max_concurrent_jobs" => 1 })
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")
        task_for(status: "running", agent: users(:two), trigger: comment("Busy"))

        assert_equal :resumed, TaskResumer.resume!(task)
        assert_equal "queued", task.reload.status
      end

      test "a resumed waiter is not folded away by a newer waiter" do
        task = task_for(status: "queued", resume_count: 1,
                        trigger_event_payload: payload_for(@trigger).merge(ResumeContext::KEY => { "reason" => "quota" }))
        newer = task_for(status: "queued", trigger: comment("Follow-up"))

        assert_empty TaskCoalescer.coalesce!(newer)
        assert_equal "queued", task.reload.status
      end

      test "resume! is idempotent" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        assert_equal :resumed, TaskResumer.resume!(task)
        assert_nil TaskResumer.resume!(task)
        assert_enqueued_jobs 1, only: AiAgentJob
        assert_equal 1, task.reload.resume_count
      end

      test "resume! leaves a turn whose reset has not arrived" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "quota",
                        resume_not_before: 1.hour.from_now)

        assert_equal :not_due, TaskResumer.resume!(task)
        assert_equal "suspended", task.reload.status
      end

      test "resume! waits for an agent that is known to be offline" do
        task = task_for(status: "suspended", agent: channel_agent, suspended_at: Time.current,
                        suspend_reason: "agent_offline", suspended_from: "delegated")

        assert_equal :unavailable, TaskResumer.resume!(task)
        assert_equal "suspended", task.reload.status

        AgentSubscription.create!(agent_id: task.agent_id, token: "back")
        assert_equal :resumed, TaskResumer.resume!(task)
      end

      test "resume! escalates a turn that waited past its TTL" do
        task = task_for(status: "suspended", suspended_at: 25.hours.ago, suspend_reason: "agent_offline")

        assert_equal :escalated, TaskResumer.resume!(task)

        assert_equal "escalated", task.reload.status
        assert_equal I18n.t("collavre.orchestration.suspension.escalated",
                            agent: @agent.display_name,
                            cause: I18n.t("collavre.orchestration.suspension.escalation_causes.expired")),
                     notices.last.content
      end

      test "a quota reset more than a day away does not expire the turn before it arrives" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "quota",
                        resume_not_before: 30.hours.from_now)

        travel 31.hours do
          assert_not TaskResumer.expired?(task)
          assert_equal :resumed, TaskResumer.resume!(task)
        end
      end

      test "resume! starts a topic-less turn directly" do
        task = Task.create!(name: "Event turn", status: "suspended", agent: @agent, suspend_reason: "server_restart",
                            suspended_at: Time.current, trigger_event_name: "system_event",
                            trigger_event_payload: { "creative" => { "id" => @creative.id } })

        assert_equal :resumed, TaskResumer.resume!(task)
        assert_equal "pending", task.reload.status
        assert_enqueued_with(job: AiAgentJob, args: [ task ])
      end

      test "a topic-less turn whose job cannot be enqueued goes back to suspended" do
        task = Task.create!(name: "Event turn", status: "suspended", agent: @agent, suspend_reason: "server_restart",
                            suspended_at: Time.current, trigger_event_name: "system_event",
                            trigger_event_payload: { "creative" => { "id" => @creative.id } })
        unsent = AiAgentJob.new(task).tap { |job| job.successfully_enqueued = false }

        AiAgentJob.stub(:perform_later, unsent) do
          assert_equal :resumed, TaskResumer.resume!(task)
          assert_equal :resumed, TaskResumer.resume!(task.reload)
        end
        task.reload
        assert_equal "suspended", task.status
        assert_equal 0, task.resume_count, "an attempt that never ran must not use up the resume budget"
        assert_empty Comment.where(user_id: nil, content: I18n.t("collavre.orchestration.suspension.resumed",
                                                                 agent: @agent.display_name))
      end

      test "a stuck promotion leaves the resumed turn queued for orphan recovery" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        AgentOrchestrator.stub(:dequeue_next_for_topic, ->(*) { raise ActiveRecord::Deadlocked, "busy" }) do
          assert_equal :resumed, TaskResumer.resume!(task)
        end
        assert_equal "queued", task.reload.status
      end

      test "a topic-scoped resume whose job cannot be enqueued goes back to the queue" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")
        unsent = AiAgentJob.new(task).tap { |job| job.successfully_enqueued = false }

        AiAgentJob.stub(:perform_later, unsent) do
          assert_equal :resumed, TaskResumer.resume!(task)
        end
        assert_equal "queued", task.reload.status,
                     "left pending it would hold the slot with no job and no recovery"
      end

      test "a topic-scoped resume whose enqueue raises goes back to the queue" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        AiAgentJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError, "queue down" }) do
          assert_equal :resumed, TaskResumer.resume!(task)
        end
        assert_equal "queued", task.reload.status,
                     "left pending it would hold the slot with no job and no recovery"
      end

      test "a promotion that fails after its claim puts the waiter back and re-raises" do
        waiter = task_for(status: "queued")

        AiAgentJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError, "queue down" }) do
          assert_raises(ActiveJob::EnqueueError) { AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id) }
        end
        assert_equal "queued", waiter.reload.status
      end

      test "the job a suspension left enqueued does not start the suspended turn" do
        task = task_for(status: "pending")
        TaskResumer.suspend!(task, reason: :server_restart)

        AiAgentJob.perform_now(task.reload)

        assert_equal "suspended", task.reload.status
      end

      test "a second job for a resumed turn that already started does nothing" do
        task = task_for(status: "pending")
        assert Workflow::TaskAdmission.start!(task, execution_job_id: "first")
        generation = ExecutionFence.generation(task.reload)

        assert_not Workflow::TaskAdmission.start!(task, execution_job_id: "second")
        assert_equal generation, ExecutionFence.generation(task.reload)
        assert_equal "first", task.trigger_event_payload[ExecutionFence::JOB_KEY]
      end

      test "resume_for_agent! resumes only that agent's due turns" do
        due = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")
        later = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "quota",
                         resume_not_before: 1.hour.from_now, trigger: comment("Later"))
        other = task_for(status: "suspended", agent: users(:two), suspended_at: Time.current,
                         suspend_reason: "agent_offline", trigger: comment("Other"))

        assert_equal [ :resumed ], TaskResumer.resume_for_agent!(@agent)
        assert_equal "pending", due.reload.status
        assert_equal "suspended", later.reload.status
        assert_equal "suspended", other.reload.status
      end

      test "sweep! resumes what is due and escalates what expired" do
        due = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")
        expired = task_for(status: "suspended", suspended_at: 2.days.ago, suspend_reason: "agent_offline",
                           agent: users(:two), trigger: comment("Old"))
        waiting = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "quota",
                           resume_not_before: 1.hour.from_now, agent: users(:three), trigger: comment("Wait"))

        TaskResumer.sweep!

        assert_equal "pending", due.reload.status
        assert_equal "escalated", expired.reload.status
        assert_equal "suspended", waiting.reload.status
      end

      test "agent_available? only blocks on positive evidence of being offline" do
        assert TaskResumer.agent_available?(@agent)
        assert_not TaskResumer.agent_available?(channel_agent)
        assert_not TaskResumer.agent_available?(nil)
      end

      test "agent_available? waits for positive liveness after an offline suspension" do
        offline = task_for(status: "suspended", suspend_reason: "agent_offline")
        restarted = task_for(status: "suspended", suspend_reason: "server_restart", trigger: comment("Restart"))

        assert_equal :unknown, @agent.agent_liveness_status
        assert_not TaskResumer.agent_available?(@agent, task: offline)
        assert TaskResumer.agent_available?(@agent, task: restarted)

        @agent.stub(:agent_liveness_status, :online) do
          assert TaskResumer.agent_available?(@agent, task: offline)
        end
      end

      test "agent_available? is held by a quota block" do
        blocked_until = 1.hour.from_now
        @agent.define_singleton_method(:quota_blocked_until) { blocked_until }
        assert_not TaskResumer.agent_available?(@agent)

        blocked_until = 1.minute.ago
        assert TaskResumer.agent_available?(@agent)

        @agent.define_singleton_method(:quota_retry_exhausted) { true }
        assert_not TaskResumer.agent_available?(@agent)
      end

      test "a session topic's turn waits for its own session, not a sibling's" do
        agent = channel_agent
        @topic.update!(primary_agent_id: agent.id, session_id: "sess-a")
        task = task_for(status: "suspended", agent: agent, suspend_reason: "agent_offline")

        AgentSubscription.create!(agent_id: agent.id, token: "sibling", session_id: "sess-b")
        assert agent.claude_channel_online?
        assert_not TaskResumer.agent_available?(agent, task: task)

        AgentSubscription.create!(agent_id: agent.id, token: "own", session_id: "sess-a")
        assert TaskResumer.agent_available?(agent, task: task)
      end

      test "claude_channel_reachable? does not gate other agents" do
        assert TaskResumer.claude_channel_reachable?(@agent, task_for(status: "queued"))
      end

      # --- execution fence ----------------------------------------------------

      test "suspend! from an earlier execution leaves the current one alone" do
        task = task_for(status: "running", trigger_event_payload: ExecutionFence.stamp(payload_for(@trigger)))
        current = ExecutionFence.generation(task)

        assert_nil TaskResumer.suspend!(task, reason: :quota, execution_generation: "earlier-attempt")
        assert_equal "running", task.reload.status

        assert_equal :suspended, TaskResumer.suspend!(task, reason: :quota, execution_generation: current)
      end

      test "resume! retires the interrupted execution but keeps its resume context" do
        task = task_for(status: "running",
                        trigger_event_payload: ExecutionFence.stamp(payload_for(@trigger), job_id: "job-1"))
        generation = ExecutionFence.generation(task)
        TaskResumer.suspend!(task, reason: :server_restart)

        TaskResumer.resume!(task)

        payload = task.reload.trigger_event_payload
        assert_not payload.key?(ExecutionFence::JOB_KEY)
        assert_not payload.key?(ExecutionFence::GENERATION_KEY)
        assert_equal "server_restart", payload.dig(ResumeContext::KEY, "reason")
        assert_nil TaskResumer.suspend!(task, reason: :quota, execution_generation: generation)
      end

      # --- reclaim_for_retry! -------------------------------------------------

      def attempt_of(job_id, status:, handoff: nil)
        payload = ExecutionFence.stamp(payload_for(@trigger), job_id: job_id)
        payload = ExecutionFence.pending_handoff(payload) if handoff
        payload[ExecutionFence::HANDOFF_KEY]["state"] = handoff if handoff
        task_for(status: status, trigger_event_payload: payload)
      end

      test "reclaim_for_retry! hands a dead running attempt back to its job" do
        task = attempt_of("job-1", status: "running")
        partial = @creative.comments.create!(user: @agent, topic: @topic, content: "Half an answer",
                                             task: task, skip_dispatch: true)

        assert_equal [ task ], TaskResumer.reclaim_for_retry!("job-1")

        task.reload
        assert_equal "pending", task.status
        assert_equal "job-1", task.trigger_event_payload[ExecutionFence::JOB_KEY],
                     "the retried job finds its row by this id"
        assert_nil ExecutionFence.generation(task), "the dead attempt's generation must stop matching"
        assert_nil partial.reload.task_id, "the retried attempt writes its own reply"
        assert_equal 0, task.resume_count, "a retry is not a resume"
      end

      test "reclaim_for_retry! takes back a delegated attempt only while its handoff never started" do
        pending = attempt_of("job-1", status: "delegated", handoff: "pending")
        started = attempt_of("job-2", status: "delegated", handoff: "started")
        completed = attempt_of("job-3", status: "delegated", handoff: "completed")
        legacy = attempt_of("job-4", status: "delegated")

        assert_equal [ pending ], %w[job-1 job-2 job-3 job-4].flat_map { |id| TaskResumer.reclaim_for_retry!(id) }
        assert_equal "pending", pending.reload.status
        assert_nil pending.trigger_event_payload[ExecutionFence::HANDOFF_KEY]
        assert_equal %w[delegated delegated delegated], [ started, completed, legacy ].map { |t| t.reload.status }
      end

      test "reclaim_for_retry! leaves a handoff from an earlier generation alone" do
        task = attempt_of("job-1", status: "delegated", handoff: "pending")
        task.trigger_event_payload[ExecutionFence::HANDOFF_KEY]["generation"] = "earlier"
        task.save!

        assert_empty TaskResumer.reclaim_for_retry!("job-1")
        assert_equal "delegated", task.reload.status
      end

      test "reclaim_for_retry! leaves other jobs' attempts and finished turns alone" do
        other = attempt_of("job-2", status: "running")
        finished = attempt_of("job-1", status: "done")

        assert_empty TaskResumer.reclaim_for_retry!("job-1")
        assert_equal "running", other.reload.status
        assert_equal "done", finished.reload.status
      end

      # --- transactions -------------------------------------------------------

      test "suspension side effects wait for the caller's transaction to commit" do
        holder = task_for(status: "running")
        waiter = task_for(status: "queued", agent: users(:two), trigger: comment("Another request"))

        Task.transaction do
          assert_equal :suspended, TaskResumer.suspend!(holder, reason: :agent_offline)
          assert_equal "queued", waiter.reload.status, "the queue must not drain before the suspension commits"
          assert_empty notices
        end

        assert_equal "pending", waiter.reload.status
        assert_equal 1, notices.count
      end

      test "a rolled-back suspension neither drains the topic nor announces itself" do
        holder = task_for(status: "running")
        waiter = task_for(status: "queued", agent: users(:two), trigger: comment("Another request"))

        Task.transaction do
          TaskResumer.suspend!(holder, reason: :agent_offline)
          raise ActiveRecord::Rollback
        end

        assert_equal "running", holder.reload.status
        assert_equal "queued", waiter.reload.status
        assert_empty notices
      end

      test "suspension effects skip the announcement for a turn a late reply already finished" do
        task = task_for(status: "running")
        tracker = ResourceTracker.for(@agent)
        tracker.reserve!(task.id)
        reply = @creative.comments.create!(user: @agent, topic: @topic, content: "The full answer",
                                           task: task, skip_dispatch: true)

        Task.transaction do
          assert_equal :suspended, TaskResumer.suspend!(task, reason: :agent_offline)
          task.update!(status: "done")
        end

        assert_equal task.id, reply.reload.task_id, "the finished turn keeps its reply"
        assert_empty notices
        assert_equal 0, tracker.active_jobs, "nothing else gives back what the suspension held"
      end

      test "suspension effects leave a turn that was already resumed to its new attempt" do
        task = task_for(status: "running")
        tracker = ResourceTracker.for(@agent)
        tracker.reserve!(task.id)

        Task.transaction do
          assert_equal :suspended, TaskResumer.suspend!(task, reason: :server_restart)
          assert_equal :resumed, TaskResumer.resume!(task)
        end

        assert_equal "pending", task.reload.status
        assert_equal 1, tracker.active_jobs, "the resumed attempt owns the task's reservation"
        assert_equal [ I18n.t("collavre.orchestration.suspension.resumed", agent: @agent.display_name) ],
                     notices.pluck(:content)
      end

      test "an escalation that was stopped before its effects ran is not announced" do
        task = task_for(status: "running", resume_count: TaskResumer::MAX_RESUMES)

        Task.transaction do
          assert_equal :escalated, TaskResumer.suspend!(task, reason: :server_restart)
          task.update!(status: "cancelled")
        end

        assert_empty notices
      end

      test "suspension effects of a task deleted before they run do nothing" do
        task = task_for(status: "queued")

        Task.transaction do
          assert_equal :suspended, TaskResumer.suspend!(task, reason: :server_restart)
          task.destroy!
        end

        assert_empty notices
      end

      test "a resume inside a transaction starts only after it commits" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        Task.transaction do
          assert_equal :resumed, TaskResumer.resume!(task)
          assert_equal "queued", task.reload.status
          assert_no_enqueued_jobs only: AiAgentJob
        end

        assert_equal "pending", task.reload.status
        assert_enqueued_with(job: AiAgentJob, args: [ task ])
      end

      test "a resume stopped before it starts is neither started nor announced" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        Task.transaction do
          assert_equal :resumed, TaskResumer.resume!(task)
          task.update!(status: "cancelled")
        end

        assert_equal "cancelled", task.reload.status
        assert_no_enqueued_jobs only: AiAgentJob
        assert_empty notices
      end

      test "a topic-less resume that is suspended again before it starts gets no job" do
        task = Task.create!(name: "Event turn", status: "suspended", agent: @agent, suspend_reason: "server_restart",
                            suspended_at: Time.current, trigger_event_name: "system_event",
                            trigger_event_payload: { "creative" => { "id" => @creative.id } })

        Task.transaction do
          assert_equal :resumed, TaskResumer.resume!(task)
          task.update!(status: "suspended")
        end

        assert_equal "suspended", task.reload.status
        assert_equal 1, task.resume_count
        assert_no_enqueued_jobs only: AiAgentJob
      end

      test "only the latest of two resumes in one transaction starts and announces" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        Task.transaction do
          assert_equal :resumed, TaskResumer.resume!(task)
          task.update!(status: "suspended")
          assert_equal :resumed, TaskResumer.resume!(task)
        end

        assert_equal "pending", task.reload.status
        assert_enqueued_jobs 1, only: AiAgentJob
        assert_equal [ I18n.t("collavre.orchestration.suspension.resumed", agent: @agent.display_name) ],
                     notices.pluck(:content)
      end

      test "an expiry escalation stopped before its effects is not announced" do
        task = task_for(status: "suspended", suspended_at: 25.hours.ago, suspend_reason: "agent_offline")

        Task.transaction do
          assert_equal :escalated, TaskResumer.resume!(task)
          task.update!(status: "cancelled")
        end

        assert_empty notices
      end

      test "resume effects of a task deleted before they run do nothing" do
        task = task_for(status: "suspended", suspended_at: Time.current, suspend_reason: "server_restart")

        Task.transaction do
          assert_equal :resumed, TaskResumer.resume!(task)
          task.destroy!
        end

        assert_no_enqueued_jobs only: AiAgentJob
        assert_empty notices
      end

      test "a resumed turn absorbs newer waiters and keeps its id and resume context" do
        # Promoted (pending) resumed turn folding the waiters behind it, as
        # AgentOrchestrator.coalesce_promoted! does.
        task = task_for(status: "pending", resume_count: 1,
                        trigger_event_payload: payload_for(@trigger).merge(ResumeContext::KEY => { "reason" => "quota" }))
        follow_up = comment("Follow-up")
        newer = task_for(status: "queued", trigger: follow_up)

        assert_equal [ newer.id ], TaskCoalescer.coalesce!(task, scope: :all)

        assert_equal "cancelled", newer.reload.status
        task.reload
        assert_equal "pending", task.status
        assert_equal({ "reason" => "quota" }, task.trigger_event_payload[ResumeContext::KEY])
        assert_includes Array(task.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]).map(&:to_i), follow_up.id
      end
    end
  end
end
