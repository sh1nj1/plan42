# frozen_string_literal: true

require "digest"

module Collavre
  module Onboarding
    class ProgressTracker
      def self.creative_created(creative:, user:)
        new(user: user).creative_created(creative)
      end

      def self.creative_updated(creative:, user:, changed_attributes:)
        new(user: user).creative_updated(creative, changed_attributes: changed_attributes)
      end

      def self.comment_created(comment:, user:)
        new(user: user).comment_created(comment)
      end

      def self.agent_replied(comment:)
        owner = comment.creative&.user
        new(user: owner).agent_replied(comment)
      end

      def initialize(user:)
        @user = user
      end

      def creative_created(creative)
        card = creative.parent
        return unless active_card?(card, "create_edit")

        card.with_lock do
          return if card.onboarding_metadata["status"] == "completed"

          attach_practice_metadata!(creative, card)
          update_card!(card, {
            "status" => "in_progress",
            "target_creative_id" => creative.id,
            "baseline_digest" => description_digest(creative),
            "started_at" => Time.current.iso8601
          })
        end
        card
      end

      def creative_updated(creative, changed_attributes:)
        metadata = creative.onboarding_metadata
        return unless active_practice?(creative, metadata)

        case metadata["step_key"]
        when "create_edit"
          return unless Array(changed_attributes).map(&:to_s).include?("description")

          card = card_for(metadata)
          return unless card&.onboarding_metadata&.dig("target_creative_id").to_i == creative.id
          return if card.onboarding_metadata["baseline_digest"] == description_digest(creative)

          complete!(card: card, practice: creative)
        when "progress_rollup"
          return unless creative.progress.to_f >= 1.0

          card = card_for(metadata)
          return unless tracked_target?(card, creative)

          complete!(card: card, practice: creative)
        end
      end

      def comment_created(comment)
        return if comment.private? || comment.user != user

        creative = comment.creative
        metadata = creative&.onboarding_metadata
        return unless active_practice?(creative, metadata)

        card = card_for(metadata)
        return unless tracked_target?(card, creative)

        case metadata["step_key"]
        when "creative_chat"
          complete!(card: card, practice: creative)
        when "mention_agent"
          mentioned_agent = MentionParser.resolve_all_users(comment.content.to_s).find do |candidate|
            candidate.ai_user? && creative.has_permission?(candidate, :feedback)
          end
          return unless mentioned_agent

          complete!(
            card: card,
            practice: creative,
            extra: { "invoked_agent_id" => mentioned_agent.id, "response_status" => "waiting" }
          )
        end
      end

      def agent_replied(comment)
        creative = comment.creative
        metadata = creative&.onboarding_metadata
        return unless comment.user&.ai_user? && active_practice?(creative, metadata)
        return unless metadata["step_key"] == "mention_agent"

        card = card_for(metadata)
        return unless tracked_target?(card, creative)
        return unless card.onboarding_metadata["invoked_agent_id"].to_i == comment.user_id

        card.with_lock do
          update_card!(card, {
            "response_status" => "responded",
            "responded_at" => Time.current.iso8601
          })
        end
        card
      end

      private

      attr_reader :user

      def active_card?(card, step_key)
        active_session?(card&.onboarding_metadata) && card&.onboarding_card? && card.user_id == user.id &&
          card.onboarding_metadata["step_key"] == step_key
      end

      def active_practice?(creative, metadata)
        active_session?(metadata) && creative&.user_id == user.id && creative.onboarding_practice? &&
          metadata&.dig("session_id").present?
      end

      def active_user?
        user.present? && user.onboarding_seeded_at.present? && user.onboarding_completed_at.nil?
      end

      def active_session?(metadata)
        return false unless active_user? && metadata&.dig("session_id").present?

        active_root&.onboarding_metadata&.dig("session_id") == metadata["session_id"]
      end

      def active_root
        @active_root ||= Creative.onboarding_guides.where(user: user).find(&:onboarding_root?)
      end

      def card_for(metadata)
        Creative.where(user: user).find do |candidate|
          candidate.onboarding_card? &&
            candidate.onboarding_metadata["session_id"] == metadata["session_id"] &&
            candidate.onboarding_metadata["step_key"] == metadata["step_key"]
        end
      end

      def attach_practice_metadata!(creative, card)
        data = creative.data.deep_dup
        data["onboarding"] = {
          "session_id" => card.onboarding_metadata["session_id"],
          "role" => "practice",
          "step_key" => card.onboarding_metadata["step_key"]
        }
        creative.update!(data: data)
      end

      def tracked_target?(card, practice)
        card&.onboarding_metadata&.dig("target_creative_id").to_i == practice.id
      end

      def complete!(card:, practice:, extra: {})
        return unless card && practice

        card.with_lock do
          return card if card.reload.onboarding_metadata["status"] == "completed"

          practice.update!(progress: 1.0) unless practice.progress.to_f >= 1.0
          update_card!(card, {
            "status" => "completed",
            "completed_at" => Time.current.iso8601
          }.merge(extra))
        end
        card
      end

      def update_card!(card, attributes)
        data = card.data.deep_dup
        data["onboarding"].merge!(attributes.stringify_keys)
        card.update!(data: data)
      end

      def description_digest(creative)
        Digest::SHA256.hexdigest(creative.description.to_s)
      end
    end
  end
end
