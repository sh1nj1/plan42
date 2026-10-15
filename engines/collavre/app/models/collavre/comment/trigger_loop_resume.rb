# frozen_string_literal: true

module Collavre
  class Comment
    # When a human user comments in a trigger topic that is awaiting user
    # input, auto-resume the trigger loop so the agent can continue working.
    module TriggerLoopResume
      extend ActiveSupport::Concern

      included do
        after_create_commit :resume_trigger_loop_if_awaiting, unless: :skip_dispatch
      end

      private

      def resume_trigger_loop_if_awaiting
        return unless trigger_loop_resume_candidate?
        # Lock-free precheck on a fresh read: almost every comment lands on a
        # creative with no loop awaiting this topic, and must not pay for a
        # write transaction + row lock just to find that out.
        return unless trigger_loop_resumable?(Creative.where(id: creative.id).pick(:data))

        progress = claim_awaiting_trigger_loop
        # Revalidate the committed turn under topic -> creative lock order.
        post_loop_resume(*progress) if progress
      rescue StandardError => e
        Rails.logger.error(
          "[Comment#resume_trigger_loop_if_awaiting] Failed for comment #{id}: " \
          "#{e.class} #{e.message}"
        )
      end

      # Human, public, non-approval replies only: private input is absent from
      # agent history, and the approval surface is not a user-resume signal.
      def trigger_loop_resume_candidate?
        public_human_loop_reply? && creative.present?
      end

      # True when the loop is awaiting user input and this comment is in its
      # trigger topic (or the loop has no trigger topic recorded).
      def trigger_loop_resumable?(data)
        loop_data = data&.dig("trigger", "loop")
        return false unless loop_data.is_a?(Hash) && loop_data["state"] == "awaiting_user"
        return false if id.present? && loop_data["current_comment_id"] == id

        trigger_topic_id = loop_data["trigger_topic_id"]
        trigger_topic_id.blank? || trigger_topic_id == topic_id
      end

      # Pessimistic lock prevents duplicate resumes from concurrent comments.
      # Returns [iteration, max, snapshot] when this comment moved the loop to
      # running, nil when the re-check under the lock finds it no longer
      # resumable (e.g. a concurrent comment resumed it after the precheck, or
      # the selected keep agent became unavailable).
      def claim_awaiting_trigger_loop
        creative.with_lock do
          data = creative.data
          next unless trigger_loop_resumable?(data)
          next if creative.keep_loop_agent_unavailable?

          loop_cfg = data["trigger"]["loop"]
          loop_cfg["state"] = "running"
          creative.update!(data: data)
          [ loop_cfg["current_iteration"] || 0, loop_cfg["max_iterations"] || 10, loop_cfg.deep_dup ]
        end
      end
    end
  end
end
