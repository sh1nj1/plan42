# frozen_string_literal: true

module Collavre
  module Orchestration
    # Identifies one execution attempt of a Task so that anything arriving on
    # behalf of an earlier attempt can be told apart from the current one.
    #
    # A suspended turn comes back as the same Task row, so the row id alone no
    # longer says which attempt a late signal belongs to: a reply, a suspend
    # request or a crash report from the interrupted attempt would otherwise
    # land on the resumed one. Every start stamps two values into the payload:
    #
    # - execution_job_id: the ActiveJob that runs this attempt, so recovery can
    #   ask the queue whether that worker is actually dead.
    # - execution_generation: a fresh token handed to the agent with the
    #   dispatch and echoed back by it, compared under the task lock.
    #
    # A Claude Channel attempt also carries channel_handoff, written with the
    # running -> delegated transition as { generation, state: "pending" }. The
    # adapter moves it to "started" before the broadcast and "completed" after,
    # so recovery can tell a dispatch that never left from one that may have.
    #
    # Resuming clears all of them, so nothing from the old attempt matches the
    # new one.
    module ExecutionFence
      JOB_KEY = "execution_job_id"
      GENERATION_KEY = "execution_generation"
      HANDOFF_KEY = "channel_handoff"
      HANDOFF_PENDING = "pending"
      KEYS = [ JOB_KEY, GENERATION_KEY, HANDOFF_KEY ].freeze

      module_function

      def stamp(payload, job_id: nil)
        stamped = clear(payload).merge(GENERATION_KEY => SecureRandom.uuid)
        job_id ? stamped.merge(JOB_KEY => job_id) : stamped
      end

      def clear(payload)
        (payload || {}).except(*KEYS)
      end

      # Drop the attempt's generation and handoff but keep its job id: the
      # same job is about to run the row again (TaskResumer.reclaim_for_retry!).
      def retire_attempt(payload)
        (payload || {}).except(GENERATION_KEY, HANDOFF_KEY)
      end

      # Whether the attempt run by this job can be run again from scratch: it
      # was still running, or it was delegated but its Channel handoff for the
      # current generation never started — nothing reached the agent.
      # Extension point for offline recovery: once recovery has handed a dead
      # run's turn to another execution, it tombstones that job id in the
      # primary database. A stale copy of the job (left in a separate queue
      # database, or retried by hand) must neither create a row nor rerun one.
      def retired?(job_id)
        defined?(Collavre::RetiredTaskExecution) && Collavre::RetiredTaskExecution.exists?(execution_job_id: job_id)
      end

      def retryable?(task, job_id)
        payload = task.trigger_event_payload
        return false unless payload.is_a?(Hash) && payload[JOB_KEY].to_s == job_id.to_s

        case task.status
        when "running" then true
        when "failed" then !task.workflow? && payload[HANDOFF_KEY].blank?
        when "delegated"
          handoff = payload[HANDOFF_KEY]
          handoff.is_a?(Hash) && handoff["state"] == HANDOFF_PENDING && handoff["generation"] == payload[GENERATION_KEY]
        else false
        end
      end

      def pending_handoff(payload)
        payload = payload || {}
        payload.merge(HANDOFF_KEY => { "generation" => payload[GENERATION_KEY], "state" => HANDOFF_PENDING })
      end

      def generation(task)
        task.trigger_event_payload.is_a?(Hash) ? task.trigger_event_payload[GENERATION_KEY] : nil
      end

      # Whether the attempt that started under this generation has been set
      # aside since: the task was resumed (generation cleared) or started again
      # (a new one). The in-process worker's counterpart of current?.
      def superseded?(task, attempt_generation)
        attempt_generation.present? && generation(task) != attempt_generation
      end

      # A caller that names no generation is a legacy client and is not fenced.
      # One that names a generation must name the current one.
      def current?(task, requested_generation)
        requested_generation.blank? || generation(task) == requested_generation.to_s
      end
    end
  end
end
