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
        # Post continue instruction outside lock (state already committed)
        post_trigger_loop_resume(*progress) if progress
      rescue StandardError => e
        Rails.logger.error(
          "[Comment#resume_trigger_loop_if_awaiting] Failed for comment #{id}: " \
          "#{e.class} #{e.message}"
        )
      end

      def trigger_loop_resume_candidate?
        return false unless user_id          # must have a user (not system)
        return false if user&.ai_user?       # must be a human, not an AI agent
        return false if approval_action?     # approval surface is not a user-resume signal; the resumed @agent turn would otherwise carry it into history

        creative.present?
      end

      # True when the loop is awaiting user input and this comment is in its
      # trigger topic (or the loop has no trigger topic recorded).
      def trigger_loop_resumable?(data)
        loop_data = data&.dig("trigger", "loop")
        return false unless loop_data.is_a?(Hash) && loop_data["state"] == "awaiting_user"

        trigger_topic_id = loop_data["trigger_topic_id"]
        trigger_topic_id.blank? || trigger_topic_id == topic_id
      end

      # Pessimistic lock prevents duplicate resumes from concurrent comments.
      # Returns [iteration, max] when this comment moved the loop to running,
      # nil when the re-check under the lock finds it no longer resumable
      # (e.g. a concurrent comment resumed it after the precheck).
      def claim_awaiting_trigger_loop
        creative.with_lock do
          data = creative.data
          next unless trigger_loop_resumable?(data)

          loop_cfg = data["trigger"]["loop"]
          loop_cfg["state"] = "running"
          creative.update!(data: data)
          [ loop_cfg["current_iteration"] || 0, loop_cfg["max_iterations"] || 10 ]
        end
      end

      def post_trigger_loop_resume(iteration, max)
        parent = creative.parent
        return unless parent&.drop_trigger_enabled?

        agent = parent.find_ai_agent(:write)
        return unless agent

        creative.comments.create!(
          content: "@#{agent.name}: #{I18n.t(
            'collavre.trigger_loop.user_resumed',
            iteration: iteration,
            max: max
          )}",
          topic_id: topic_id,
          private: false,
          user: creative.user,
          skip_dispatch: false
        )
      end
    end
  end
end
