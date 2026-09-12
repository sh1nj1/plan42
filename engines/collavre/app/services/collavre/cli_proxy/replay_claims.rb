# frozen_string_literal: true

module Collavre
  module CliProxy
    # Coalescing transfers requests, including responsibility for their login
    # cards. Move all claims in the same transaction before cancelling siblings.
    module ReplayClaims
      KEYS = %w[inline_login_task_id inline_login_task_ids].freeze

      def self.ids(payload)
        (Array(payload&.fetch(KEYS.first, nil)) + Array(payload&.fetch(KEYS.last, nil))).compact.uniq
      end

      # Reauthentication adds a new card without losing claims inherited from
      # earlier attempts or queued-turn coalescing.
      def self.attach(payload, task_id)
        inherited = ids(payload)
        payload = payload.merge(KEYS.first => task_id)
        payload[KEYS.last] = inherited if inherited.any?
        payload
      end

      # The reply task owns loop completion; settling its historical login card
      # must not evaluate that card's authentication notice as another result.
      def self.complete!(task)
        task.with_lock do
          data = task.trigger_event_payload&.fetch("engine_login", {}) || {}
          return unless data["resumed"] && data["retryable"]

          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" =>
            data.merge("retryable" => false, "replay_completed" => true)))
        end
      end

      # Caller holds the survivor and sibling locks for the entire fold.
      def self.transfer!(keep, siblings)
        claimed = siblings.select { |task| ids(task.trigger_event_payload).any? }
        return if claimed.empty?

        inherited = ([ keep ] + claimed).flat_map { |task| ids(task.trigger_event_payload) }.uniq
        keep.update!(trigger_event_payload: keep.trigger_event_payload.merge(KEYS.last => inherited))
        claimed.each do |task|
          task.update!(trigger_event_payload: task.trigger_event_payload.except(*KEYS))
        end
      end
    end
  end
end
