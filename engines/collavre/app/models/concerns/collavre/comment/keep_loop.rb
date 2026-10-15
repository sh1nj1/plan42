# frozen_string_literal: true

module Collavre
  class Comment
    module KeepLoop
      extend ActiveSupport::Concern

      included do
        attr_accessor :keep_loop_options, :loop_continuation
        after_create :track_loop_turn, if: :loop_continuation
        after_create :initialize_keep_loop
      end

      private

      def loop_dispatch_chat
        chat = { content: content }
        config = creative&.data&.dig("trigger", "loop")
        if config && config["source"] == "keep" && config["agent_id"].present? &&
           [ config["start_comment_id"], config["current_comment_id"] ].include?(id)
          chat[:mentioned_users] = [ { id: config["agent_id"] } ]
        end
        chat
      end

      def public_human_loop_reply?
        user_id.present? && !user&.ai_user? && !approval_action? && !self.private?
      end

      def blocked_keep_reply?
        config = creative.data&.dig("trigger", "loop")
        config && config["state"] == "awaiting_user" && config["trigger_topic_id"] == topic_id &&
          config["source"] == "keep" && config["agent_id"].present?
      end

      def track_loop_turn
        creative.with_lock do
          data = (creative.data || {}).deep_dup
          loop_data = data.dig("trigger", "loop")
          return unless loop_data && loop_data["source"] == "keep" && loop_data["state"] == "running"

          loop_data["current_comment_id"] = id
          creative.update!(data: data)
        end
      end

      def reconcile_loop_dispatch(agents)
        return unless creative.keep_loop?

        creative.with_lock do
          data = (creative.data || {}).deep_dup
          loop_data = data.dig("trigger", "loop")
          return unless loop_data && loop_data["source"] == "keep" && loop_data["state"] == "running"
          return unless loop_data["current_comment_id"] == id && agents.blank?

          loop_data["state"] = "awaiting_user"
          creative.update!(data: data)
        end
        creative.comments.create!(content: I18n.t("collavre.comments.keep_command.no_agent"),
                                  topic_id: topic_id, skip_default_user: true)
      end

      def post_loop_resume(iteration, max)
        return unless creative.trigger_loop_enabled?

        agent = creative.trigger_loop_agent
        return unless agent || creative.keep_loop?

        creative.comments.create!(
          content: "#{"@#{agent.name}: " if agent}#{I18n.t(
            'collavre.trigger_loop.user_resumed',
            iteration: iteration,
            max: max
          )}",
          topic_id: topic_id,
          private: false,
          user: creative.user,
          loop_continuation: true, skip_dispatch: false
        )
      end

      def initialize_keep_loop
        return unless keep_loop_options

        applied = Comments::TopicMutation.call(topic_id, creative_id) { persist_keep_loop }
        return if applied

        errors.add(:topic, I18n.t("collavre.comments.invalid_topic"))
        raise ActiveRecord::RecordInvalid, self
      end

      def persist_keep_loop
        creative.with_lock do
          if %w[running pending_verification].include?(creative.data&.dig("trigger", "loop", "state"))
            errors.add(:base, I18n.t("collavre.comments.keep_command.already_running"))
            raise ActiveRecord::RecordInvalid, self
          end

          data = (creative.data || {}).deep_dup
          data["trigger"] ||= {}
          data["trigger"]["loop"] = TriggerLoopConfig.build(topic_id, source: "keep", start_comment_id: id, current_comment_id: id, **keep_loop_options)
          creative.update!(data: data)
        end
      end
    end
  end
end
