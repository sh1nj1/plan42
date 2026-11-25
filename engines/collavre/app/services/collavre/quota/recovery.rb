# frozen_string_literal: true

module Collavre
  module Quota
    class Recovery
      MAX_PROBES = 3
      BACKOFF = 30.minutes

      def self.blocked?(agent)
        window_blocked?(agent) || agent.quota_retry_count.positive?
      end

      def self.window_blocked?(agent)
        agent.quota_retry_exhausted? || agent.quota_blocked_until&.future?
      end

      # Serialize competing failures for the same agent, then check the task's
      # execution state. A repeated hook must not spend another probe or enqueue
      # a second reservation. TaskResumer owns enqueue and crash recovery.
      def self.suspend!(task, error, expected_generation: nil)
        agent = task.agent
        agent.with_lock do
          task.with_lock do
            return unless %w[running delegated].include?(task.status)
            return if expected_generation && !Orchestration::ExecutionFence.current?(task, expected_generation)
            return park_existing_block(task, agent, expected_generation) if window_blocked?(agent) || !Probe.available?(agent, task)

            renew_block(task, agent, error, expected_generation)
          end
        end
      end

      def self.renew_block(task, agent, error, expected_generation)
        count = agent.quota_retry_count + 1
        exhausted = count > MAX_PROBES
        deadline = unless exhausted
          reset = error.reset_at || Time.current + BACKOFF * (2**(count - 1))
          [ reset + Random.rand(5..30).seconds, agent.quota_blocked_until ].compact.max
        end
        result = Orchestration::TaskResumer.suspend!(task, reason: "quota", resume_not_before: deadline,
                                                     execution_generation: expected_generation)
        return unless result

        agent.update!(quota_retry_count: count, quota_retry_exhausted: exhausted, quota_blocked_until: deadline,
                      quota_probe_task_id: task.id, quota_probe_generation: nil)
        Task.suspended.where(agent_id: agent.id, suspend_reason: "quota").where.not(id: task.id)
            .update_all(resume_not_before: deadline)
        ActiveRecord.after_all_transactions_commit { Notice.exhausted!(task) } if exhausted
        result
      end
      private_class_method :renew_block

      # Concurrent turns can all fail against the same closed quota window.
      # They share the existing reservation; only a later probe spends a retry.
      def self.park_existing_block(task, agent, generation)
        Orchestration::TaskResumer.suspend!(task, reason: "quota", resume_not_before: agent.quota_blocked_until,
                                            execution_generation: generation)
      end

      def self.guard!(task)
        agent = task.agent
        agent.with_lock do
          if window_blocked?(agent) || !Probe.available?(agent, task)
            result = park_existing_block(task, agent, Orchestration::ExecutionFence.generation(task))
            raise CancelledError unless result
          else
            Probe.claim!(agent, task)
            return
          end
        end
        # Raise only after committing the parked task and its reservation.
        raise TaskSuspendedError
      end

      # Only the elected execution may reopen the quota window. A sibling's
      # success or an old reply cannot clear a newer failure's reservation.
      def self.succeeded!(agent, task:, execution_generation: Orchestration::ExecutionFence.generation(task))
        agent.with_lock do
          return if window_blocked?(agent) || !Probe.completed?(agent, task, execution_generation)

          agent.update!(quota_retry_count: 0, quota_blocked_until: nil,
                        quota_probe_task_id: nil, quota_probe_generation: nil)
          ActiveRecord.after_all_transactions_commit { resume_backlog(agent.id) }
        end
      end

      def self.resume_backlog(agent_id)
        ResumeSuspendedTasksJob.perform_later(agent_id: agent_id)
      rescue StandardError => error
        # The recurring sweep also observes the cleared block. A queue outage
        # must not turn a committed successful reply into an HTTP failure.
        Rails.logger.warn("[Quota] Could not resume backlog for agent #{agent_id}: #{error.class}")
      end
      private_class_method :resume_backlog
    end
  end
end
