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

      def pending_handoff(payload)
        payload = payload || {}
        payload.merge(HANDOFF_KEY => { "generation" => payload[GENERATION_KEY], "state" => HANDOFF_PENDING })
      end

      def generation(task)
        task.trigger_event_payload.is_a?(Hash) ? task.trigger_event_payload[GENERATION_KEY] : nil
      end

      # A caller that names no generation is a legacy client and is not fenced.
      # One that names a generation must name the current one.
      def current?(task, requested_generation)
        requested_generation.blank? || generation(task) == requested_generation.to_s
      end
    end
  end
end
