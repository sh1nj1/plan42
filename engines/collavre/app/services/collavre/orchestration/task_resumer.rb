# frozen_string_literal: true

module Collavre
  module Orchestration
    # The one place a turn is set aside and later picked back up.
    #
    # A turn can be interrupted by things the agent cannot recover from on its
    # own — its session went offline, the server restarted under it, its
    # provider quota ran out. Ending it (cancelled/failed) loses the user's
    # request; leaving it running holds the topic until StuckDetector gives up
    # on it. Suspending keeps the same Task row, gives back everything it held,
    # and brings it back later through the ordinary admission path.
    #
    #   running/delegated/pending/queued ──suspend!──▶ suspended
    #   suspended ──resume!──▶ queued ─▶ (promotion) ─▶ pending ─▶ AiAgentJob
    #   suspended ──TTL / MAX_RESUMES──▶ escalated
    #
    # Resuming re-queues rather than starting the job directly, so the resumed
    # turn takes the topic slot, folds comments that arrived while it was away
    # (TaskCoalescer), refreshes its anchor and re-checks the topic's assignment
    # and the agent's presence exactly as any promoted waiter does.
    class TaskResumer
      # pending_approval is deliberately absent: it is waiting on a person, not
      # on a worker, and its approval prompt would otherwise resume a turn that
      # has been restarted from scratch.
      SUSPENDABLE_STATUSES = %w[running delegated pending queued suspended].freeze

      # Statuses that held the topic slot and the ResourceTracker reservation.
      SLOT_HOLDING_STATUSES = %w[running delegated pending].freeze

      # A turn interrupted this many times is not going to finish on its own.
      MAX_RESUMES = 3

      # How long a suspended turn may wait, counted from the later of when it
      # was suspended and when it was allowed to resume — so a quota reset more
      # than a day away does not expire the turn before the reset arrives.
      SUSPEND_TTL = 24.hours

      NOTICE_SCOPE = "collavre.orchestration.suspension"

      class << self
        # @param execution_generation [String, nil] the ExecutionFence generation
        #   the caller acted on. When given, a task that has since been resumed
        #   (a new generation) is left alone.
        # @return [:suspended, :escalated, nil] nil when the task was no longer
        #   suspendable (a reply landed, it was stopped, it moved on to a newer
        #   execution) — the caller lost the race and must leave the task alone.
        #
        # Everything past the row update runs after the caller's outermost
        # transaction commits: draining the topic or posting a notice for a
        # suspension that is then rolled back would promote or announce work
        # that never actually stopped.
        def suspend!(task, reason:, resume_not_before: nil, execution_generation: nil)
          reason = reason.to_s
          raise ArgumentError, "Unknown suspend reason: #{reason}" unless Task::SUSPEND_REASONS.include?(reason)

          outcome, previous_status, announce =
            transition_to_suspended(task, reason, resume_not_before, execution_generation)
          return if outcome.nil?

          suspension = { outcome: outcome, from: previous_status, announce: announce, resume_count: task.resume_count }
          ActiveRecord.after_all_transactions_commit { after_suspend(task, suspension) }
          outcome
        end

        # @return [:resumed, :not_due, :unavailable, :escalated, nil] nil when
        #   the task is not suspended (already resumed, replied to, or stopped).
        def resume!(task, now: Time.current)
          outcome = task.with_lock do
            next unless task.suspended?
            next :not_due if task.resume_not_before && task.resume_not_before > now

            if expired?(task, now)
              task.update!(status: "escalated")
              next :escalated
            end
            next :unavailable unless agent_available?(task.agent, task: task)

            task.update!(
              status: topic_scoped?(task) ? "queued" : "pending",
              resume_count: task.resume_count + 1,
              waiting_notice_scope: nil,
              # The interrupted attempt's owner and generation stop matching
              # here; the next start stamps fresh ones.
              trigger_event_payload: ExecutionFence.clear(task.trigger_event_payload)
            )
            :resumed
          end

          if outcome.in?(%i[escalated resumed])
            resumption = { outcome: outcome, resume_count: task.resume_count }
            ActiveRecord.after_all_transactions_commit { after_resume(task, resumption) }
          end
          outcome
        end

        # Hand a dead attempt back to the job that is about to run it again.
        #
        # For a queue retry of a failed execution (SolidQueue's
        # FailedExecution#retry): the caller has confirmed the job's owner
        # failed and calls this in the same transaction that makes the job
        # ready again. The row the dead attempt left running — or delegated
        # with its Channel handoff still pending, so nothing reached the agent —
        # goes back to pending with a fresh generation to come, which the retried
        # job starts like any promoted turn. The job id is kept: it is how a
        # retried dispatch job (agent_id, context) finds its row instead of
        # creating a second one (AiAgentJob.reclaimed_task).
        #
        # A delegated attempt whose handoff started or completed may already be
        # with the agent, and is left to its reply or to stuck recovery.
        #
        # @return [Array<Task>] the rows handed back
        def reclaim_for_retry!(execution_job_id)
          Task.where(status: %w[running delegated])
              .where("trigger_event_payload->>'#{ExecutionFence::JOB_KEY}' = ?", execution_job_id.to_s)
              .select { |task| reclaim_task_for_retry!(task, execution_job_id.to_s) }
        end

        # Resume every suspended turn of this agent that is due. For the moment
        # an agent comes back — a Claude Channel reconnect, a health probe that
        # sees it online again.
        def resume_for_agent!(agent, now: Time.current)
          agent_id = agent.respond_to?(:id) ? agent.id : agent
          due(now).where(agent_id: agent_id).order(:created_at).map { |task| resume!(task, now: now) }
        end

        # Resume what is due and escalate what has waited too long. The
        # recurring backstop behind every scheduled or event-driven resume: a
        # lost job, a failed enqueue or a missed reconnect all end up here.
        def sweep!(now: Time.current)
          Task.suspended.find_each.map { |task| resume!(task, now: now) }
        end

        def due(now = Time.current)
          Task.suspended.where(resume_not_before: nil)
              .or(Task.suspended.where(resume_not_before: ..now))
        end

        def expired?(task, now = Time.current)
          waiting_since = [ task.suspended_at, task.resume_not_before ].compact.max
          waiting_since.present? && waiting_since + SUSPEND_TTL < now
        end

        # Whether the agent can take the turn back.
        #
        # - A quota block (PR 3's quota_blocked_until / quota_retry_exhausted,
        #   read only when the columns exist) holds every resume.
        # - A turn on a Claude Channel session topic belongs to that one
        #   session: another live session of the same agent does not answer it.
        # - A turn suspended because the agent went offline waits for positive
        #   evidence it is back from agents that report liveness at all.
        # - Otherwise only positive evidence of being offline blocks: an agent
        #   with no liveness signal (:unknown) — e.g. after a server restart —
        #   would otherwise wait out the whole TTL for nothing.
        def agent_available?(agent, task: nil)
          return false if agent.blank? || quota_blocked?(agent)
          return false unless claude_channel_reachable?(agent, task)

          status = agent.agent_liveness_status
          return status == :online if task&.suspend_reason == "agent_offline" && reports_liveness?(agent)

          status != :offline
        end

        # Whether a Claude Channel client can receive this task's dispatch: the
        # task's own session for a session topic, any live session otherwise.
        # Always true for agents that are not Claude Channel agents.
        def claude_channel_reachable?(agent, task = nil)
          return true unless agent.claude_channel_agent?

          session_id = session_id_for(agent, task)
          return agent.claude_channel_online? unless session_id

          AgentSubscription.live.where(agent_id: agent.id, session_id: session_id).exists?
        end

        private

        def reclaim_task_for_retry!(task, execution_job_id)
          previous_status = task.with_lock do
            next unless ExecutionFence.retryable?(task, execution_job_id)

            status = task.status
            task.update!(status: "pending", trigger_event_payload: ExecutionFence.retire_attempt(task.trigger_event_payload))
            status
          end
          return false unless previous_status

          ActiveRecord.after_all_transactions_commit { detach_partial_reply(task) } if previous_status == "running"
          true
        end

        def quota_blocked?(agent)
          (agent.respond_to?(:quota_blocked_until) && agent.quota_blocked_until&.future?) ||
            (agent.respond_to?(:quota_retry_exhausted) && agent.quota_retry_exhausted)
        end

        def reports_liveness?(agent)
          agent.claude_channel_agent? || agent.cli_proxy_agent? || agent.endpoint_health_supported?
        end

        def session_id_for(agent, task)
          return unless task&.topic_id

          Topic.where(id: task.topic_id, primary_agent_id: agent.id).where.not(session_id: nil).pick(:session_id)
        end

        # The row lock is gone by the time this runs, so a late /reply, a Stop
        # or a resume may already have moved the task on. What the suspension
        # held is still given back — nothing else releases it for a turn that
        # left through the claim or Stop path — unless a resume has taken the
        # task back: the resumed attempt now owns the task's reservation (keyed
        # by task id) and its reply. The notices, the reply detach and the
        # scheduled resume describe this suspension only while it still stands.
        def after_suspend(task, suspension)
          task.reload
          return unless task.resume_count == suspension[:resume_count]

          release_held_work(task, suspension[:from])
          return unless task.status == (suspension[:outcome] == :escalated ? "escalated" : "suspended")

          detach_partial_reply(task) if suspension[:from] == "running"
          if suspension[:outcome] == :escalated
            post_notice(task, "escalated", cause: I18n.t("#{NOTICE_SCOPE}.escalation_causes.too_many_resumes"))
          else
            post_suspended_notice(task) if suspension[:announce]
            schedule_resume(task) if task.resume_not_before
          end
        rescue ActiveRecord::RecordNotFound
          nil
        end

        # Runs once the row lock is gone too, so a Stop, a late reply or another
        # suspension may already have moved the task on. Only a turn still where
        # this resume left it is started and announced.
        def after_resume(task, resumption)
          task.reload
          return unless task.resume_count == resumption[:resume_count]

          if resumption[:outcome] == :escalated
            post_notice(task, "escalated", cause: I18n.t("#{NOTICE_SCOPE}.escalation_causes.expired")) if task.status == "escalated"
          elsif task.status.in?(%w[queued pending]) && start(task)
            post_notice(task, "resumed")
          end
        rescue ActiveRecord::RecordNotFound
          nil
        end

        # @return [Array(outcome, previous_status, announce)]
        def transition_to_suspended(task, reason, resume_not_before, execution_generation)
          task.with_lock do
            next [] unless SUSPENDABLE_STATUSES.include?(task.status)
            next [] unless ExecutionFence.current?(task, execution_generation)

            previous_status = task.status
            if task.resume_count >= MAX_RESUMES
              task.update!(status: "escalated")
              next [ :escalated, previous_status, false ]
            end

            resuspend = previous_status == "suspended"
            announce = !resuspend || task.resume_not_before != resume_not_before
            task.update!(
              status: "suspended",
              suspend_reason: reason,
              suspended_at: resuspend ? task.suspended_at : Time.current,
              suspended_from: resuspend ? task.suspended_from : previous_status,
              resume_not_before: resume_not_before,
              trigger_event_payload: (task.trigger_event_payload || {})
                .merge(ResumeContext::KEY => ResumeContext.capture(task, reason: reason))
            )
            [ :suspended, previous_status, announce ]
          end
        end

        def topic_scoped?(task)
          task.trigger_event_payload.is_a?(Hash) && task.trigger_event_payload.key?("topic")
        end

        # Hand the topic slot and the agent reservation back so the rest of the
        # topic keeps moving while this turn waits. Only a status that held
        # them has anything to release; a queued waiter only leaves the queue.
        def release_held_work(task, previous_status)
          Comment.remove_waiter_notices!(creative_id: task.creative_id, topic_id: task.topic_id, task_ids: task.id)
          return unless SLOT_HOLDING_STATUSES.include?(previous_status)

          if task.agent
            ResourceTracker.for(task.agent).release!(task.id)
            broadcast_idle(task)
          end
          AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id) if topic_scoped?(task)
        end

        # Nothing is streaming any more, and the worker that would have cleared
        # the typing indicator is gone or unwinding through TaskSuspendedError.
        def broadcast_idle(task)
          creative = Creative.find_by(id: task.creative_id)&.effective_origin
          return unless creative

          AiAgent::AgentLifecycleManager.new(task: task, agent: task.agent, creative: creative).broadcast_status("idle")
        rescue StandardError => e
          Rails.logger.error("[TaskResumer] Could not clear typing indicator for task #{task.id}: #{e.class}: #{e.message}")
        end

        # The interrupted attempt's streamed reply stays visible — the user has
        # read it — but it is no longer this turn's reply: the resumed attempt
        # writes its own. A reply that never got past the placeholder is removed.
        def detach_partial_reply(task)
          reply = task.reply_comment
          return unless reply

          if reply.content.to_s.strip.in?([ "", Comment::STREAMING_PLACEHOLDER_CONTENT ])
            reply.destroy!
          else
            reply.update_column(:task_id, nil)
            reply.broadcast_replace_to(
              [ reply.creative, :comments ],
              partial: "collavre/comments/comment",
              locals: { comment: reply, streaming: false }
            )
          end
        rescue StandardError => e
          Rails.logger.error("[TaskResumer] Could not detach partial reply of task #{task.id}: #{e.class}: #{e.message}")
        end

        # @return [Boolean] whether the turn is on its way back. A queued waiter
        #   that failed to promote still is — StuckDetector's orphan recovery
        #   picks it up. A topic-less task has no queue behind it, so it goes
        #   back to suspended for the next sweep, and the attempt that never ran
        #   is neither counted against MAX_RESUMES nor announced.
        def start(task)
          if topic_scoped?(task)
            AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          else
            job = AiAgentJob.perform_later(task)
            raise ActiveJob::EnqueueError, "AiAgentJob was not enqueued" unless job&.successfully_enqueued?
          end
          true
        rescue StandardError => e
          Rails.logger.error("[TaskResumer] Could not start resumed task #{task.id}: #{e.class}: #{e.message}")
          return true if topic_scoped?(task)

          Task.where(id: task.id, status: "pending")
              .update_all(status: "suspended", resume_count: task.resume_count - 1, updated_at: Time.current)
          false
        end

        def schedule_resume(task)
          ResumeSuspendedTasksJob.set(wait_until: task.resume_not_before).perform_later(task_id: task.id)
        rescue StandardError => e
          # The recurring sweep resumes it anyway once it is due.
          Rails.logger.error("[TaskResumer] Could not schedule resume of task #{task.id}: #{e.class}: #{e.message}")
        end

        def post_suspended_notice(task)
          stop_control = { waiting_notice_scope: Comment::SuspensionNotice::SCOPE, waiting_notice_task_id: task.id }
          if task.suspend_reason == "quota" && task.resume_not_before
            post_notice(task, "suspended.quota_until", time: notice_time(task.resume_not_before), **stop_control)
          else
            post_notice(task, "suspended.#{task.suspend_reason}", **stop_control)
          end
        end

        # Server time with its zone named, since readers may be anywhere.
        def notice_time(time)
          time.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")
        end

        # Authorless and non-dispatching: the notice must not wake any agent,
        # including the one it is about.
        def post_notice(task, key, waiting_notice_scope: nil, waiting_notice_task_id: nil, **params)
          creative = Creative.find_by(id: task.creative_id || task.trigger_event_payload&.dig("creative", "id"))
          return unless creative

          creative.effective_origin.comments.create!(
            content: I18n.t("#{NOTICE_SCOPE}.#{key}", agent: task.agent&.display_name, **params),
            topic_id: task.topic_id,
            private: false,
            skip_default_user: true,
            skip_dispatch: true,
            waiting_notice_scope: waiting_notice_scope,
            waiting_notice_task_id: waiting_notice_task_id
          )
        rescue StandardError => e
          Rails.logger.error("[TaskResumer] Could not post #{key} notice for task #{task.id}: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
