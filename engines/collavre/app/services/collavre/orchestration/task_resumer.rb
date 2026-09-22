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
        # @return [:suspended, :escalated, nil] nil when the task was no longer
        #   suspendable (a reply landed, it was stopped) — the caller lost the
        #   race and must leave the task alone.
        def suspend!(task, reason:, resume_not_before: nil)
          reason = reason.to_s
          raise ArgumentError, "Unknown suspend reason: #{reason}" unless Task::SUSPEND_REASONS.include?(reason)

          outcome, previous_status, announce = transition_to_suspended(task, reason, resume_not_before)
          return if outcome.nil?

          release_held_work(task, previous_status)
          detach_partial_reply(task) if previous_status == "running"
          if outcome == :escalated
            post_notice(task, "escalated", cause: I18n.t("#{NOTICE_SCOPE}.escalation_causes.too_many_resumes"))
          else
            post_suspended_notice(task) if announce
            schedule_resume(task) if task.resume_not_before
          end
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
            next :unavailable unless agent_available?(task.agent)

            task.update!(
              status: topic_scoped?(task) ? "queued" : "pending",
              resume_count: task.resume_count + 1,
              waiting_notice_scope: nil
            )
            :resumed
          end

          case outcome
          when :escalated
            post_notice(task, "escalated", cause: I18n.t("#{NOTICE_SCOPE}.escalation_causes.expired"))
          when :resumed
            post_notice(task, "resumed")
            start(task)
          end
          outcome
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

        # Whether the agent can take the turn back. Only positive evidence of
        # being offline blocks a resume: an agent with no liveness signal at all
        # (:unknown) would otherwise wait out the whole TTL for nothing.
        def agent_available?(agent)
          agent.present? && agent.agent_liveness_status != :offline
        end

        private

        # @return [Array(outcome, previous_status, announce)]
        def transition_to_suspended(task, reason, resume_not_before)
          task.with_lock do
            next [] unless SUSPENDABLE_STATUSES.include?(task.status)

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

        def start(task)
          if topic_scoped?(task)
            AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          else
            job = AiAgentJob.perform_later(task)
            raise ActiveJob::EnqueueError, "AiAgentJob was not enqueued" unless job&.successfully_enqueued?
          end
        rescue StandardError => e
          # A queued waiter that failed to promote is picked up by StuckDetector's
          # orphan recovery. A topic-less task has no queue behind it, so put it
          # back to suspended for the next sweep rather than leave it pending
          # with no job.
          Rails.logger.error("[TaskResumer] Could not start resumed task #{task.id}: #{e.class}: #{e.message}")
          Task.where(id: task.id, status: "pending").update_all(status: "suspended", updated_at: Time.current)
        end

        def schedule_resume(task)
          ResumeSuspendedTasksJob.set(wait_until: task.resume_not_before).perform_later(task_id: task.id)
        rescue StandardError => e
          # The recurring sweep resumes it anyway once it is due.
          Rails.logger.error("[TaskResumer] Could not schedule resume of task #{task.id}: #{e.class}: #{e.message}")
        end

        def post_suspended_notice(task)
          if task.suspend_reason == "quota" && task.resume_not_before
            post_notice(task, "suspended.quota_until", time: notice_time(task.resume_not_before))
          else
            post_notice(task, "suspended.#{task.suspend_reason}")
          end
        end

        # Server time with its zone named, since readers may be anywhere.
        def notice_time(time)
          time.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")
        end

        # Authorless and non-dispatching: the notice must not wake any agent,
        # including the one it is about.
        def post_notice(task, key, **params)
          creative = Creative.find_by(id: task.creative_id || task.trigger_event_payload&.dig("creative", "id"))
          return unless creative

          creative.effective_origin.comments.create!(
            content: I18n.t("#{NOTICE_SCOPE}.#{key}", agent: task.agent&.display_name, **params),
            topic_id: task.topic_id,
            private: false,
            skip_default_user: true,
            skip_dispatch: true
          )
        rescue StandardError => e
          Rails.logger.error("[TaskResumer] Could not post #{key} notice for task #{task.id}: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
