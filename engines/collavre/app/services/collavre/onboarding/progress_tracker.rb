# frozen_string_literal: true

module Collavre
  module Onboarding
    # Records only successful domain operations. Client clicks are restricted to
    # the explicitly UI-only first step; all write steps arrive from controllers.
    class ProgressTracker
      def self.record(user:, event:, creative: nil, comment: nil, before_description: nil, before_progress: nil, session: nil)
        new(user: user, event: event, creative: creative, comment: comment,
            before_description: before_description, before_progress: before_progress, session: session).record
      end

      def initialize(user:, event:, creative:, comment:, before_description:, before_progress:, session:)
        @user = user
        @event = event.to_sym
        @creative = creative
        @comment = comment
        @before_description = before_description
        @before_progress = before_progress
        @session = session
      end

      def record
        session = @session || Session.for_user(user)
        return unless session

        step = session.current_step
        return unless step && expected_event?(step) && valid_subject?(session)

        session.update! do |onboarding|
          steps = onboarding["steps"] ||= {}
          next if steps.dig(step.key.to_s, "status") == "completed"

          steps[step.key.to_s] = { "status" => "completed", "completed_at" => Time.current.iso8601 }
          next_step = session.scenario.steps[session.scenario.steps.index(step) + 1]
          onboarding["current_step"] = next_step&.key&.to_s || "complete"
        end
      end

      private

      attr_reader :user, :event, :creative, :comment, :before_description, :before_progress

      def expected_event?(step)
        step.completion.to_sym == event
      end

      def valid_subject?(session)
        practices = session.practice_creatives.index_by(&:id)
        case event
        when :ui
          true
        when :progress_changed
          creative&.id == session.practice_creative_ids.first && creative.user_id == user.id &&
            before_progress.to_f < 1 && creative.progress.to_f >= 1
        when :description_changed
          creative&.id == session.practice_creative_ids.second && creative.user_id == user.id &&
            Digest::SHA256.hexdigest(before_description.to_s) != Digest::SHA256.hexdigest(creative.description.to_s)
        when :comment_created
          comment&.user_id == user.id && !comment.private? && practices.key?(comment.creative_id) &&
            MentionParser.resolve_all_users(comment.content).none?(&:ai_user?)
        when :agent_mentioned
          comment&.user_id == user.id && !comment.private? && practices.key?(comment.creative_id) &&
            eligible_mentioned_agents(comment).any?
        else
          false
        end
      end

      def eligible_mentioned_agents(comment)
        mentioned_ids = MentionParser.resolve_all_users(comment.content).select(&:ai_user?).map(&:id)
        return [] if mentioned_ids.empty?

        User.mentionable_for(comment.creative).where(id: mentioned_ids).select do |agent|
          agent.ai_user? && comment.creative.has_permission?(agent, :feedback)
        end
      end
    end
  end
end
