# frozen_string_literal: true

module Collavre
  module Quota
    class Recovery
      MAX_PROBES = 3
      BACKOFF = 30.minutes

      def self.blocked?(agent)
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
            return park_existing_block(task, agent, expected_generation) if blocked?(agent)

            count = agent.quota_retry_count + 1
            exhausted = count > MAX_PROBES
            deadline = unless exhausted
              reset = error.reset_at || Time.current + BACKOFF * (2**(count - 1))
              [ reset + Random.rand(5..30).seconds, agent.quota_blocked_until ].compact.max
            end
            result = Orchestration::TaskResumer.suspend!(task, reason: "quota", resume_not_before: deadline,
                                                         execution_generation: expected_generation)
            return unless result

            agent.update!(quota_retry_count: count, quota_retry_exhausted: exhausted, quota_blocked_until: deadline)
            ActiveRecord.after_all_transactions_commit { Notice.exhausted!(task) } if exhausted
            result
          end
        end
      end

      # Concurrent turns can all fail against the same closed quota window.
      # They share the existing reservation; only a later probe spends a retry.
      def self.park_existing_block(task, agent, generation)
        Orchestration::TaskResumer.suspend!(task, reason: "quota", resume_not_before: agent.quota_blocked_until,
                                            execution_generation: generation)
      end

      def self.guard!(task)
        agent = task.agent.reload
        return unless blocked?(agent)

        result = Orchestration::TaskResumer.suspend!(task, reason: "quota", resume_not_before: agent.quota_blocked_until)
        raise CancelledError unless result

        raise TaskSuspendedError
      end

      # A sibling's newer failure must survive this turn's late success.
      def self.succeeded!(agent)
        agent.with_lock do
          return if blocked?(agent)
          return if agent.quota_retry_count.zero?

          agent.update!(quota_retry_count: 0, quota_blocked_until: nil)
        end
      end
    end
  end
end
