# frozen_string_literal: true

module Collavre
  module AiAgent
    # Handles AI agent review workflows: eligibility checks,
    # in-place content updates, and completion reactions.
    class ReviewHandler
      def initialize(original_comment, agent)
        @original_comment = original_comment
        @agent = agent
      end

      # Class-level convenience for eligibility checks.
      def self.eligible?(original_comment, agent)
        new(original_comment, agent).eligible?
      end

      def eligible?
        return false unless @original_comment&.review_message?

        quoted_comment = @original_comment.quoted_comment
        return false unless quoted_comment
        return false unless quoted_comment.user_id == @agent.id
        return false unless quoted_comment.creative_id == @original_comment.creative_id
        return false if quoted_comment.private?
        return false unless quoted_comment.topic_id == @original_comment.topic_id

        true
      end

      # Update the quoted comment with the AI response content.
      # Returns true if the review was handled, false otherwise.
      def handle(response_content, task:)
        return false unless eligible?

        quoted_comment = @original_comment.quoted_comment

        # Save old content as a version (only if not already versioned, e.g. first review)
        unless quoted_comment.comment_versions.exists?(content: quoted_comment.content)
          quoted_comment.comment_versions.create!(
            content: quoted_comment.content,
            version_number: quoted_comment.next_version_number
          )
        end

        # Save new content as the latest version
        new_version = quoted_comment.comment_versions.create!(
          content: response_content,
          version_number: quoted_comment.next_version_number,
          review_comment: @original_comment
        )

        # Update content and point to the new version
        quoted_comment.update!(content: response_content, selected_version_id: new_version.id)

        task.task_actions.create!(
          action_type: "review_updated",
          payload: {
            quoted_comment_id: quoted_comment.id,
            original_comment_id: @original_comment.id,
            content: response_content
          },
          status: "done"
        )

        true
      end

      # Add a completion reaction emoji to the review comment.
      def add_completion_reaction
        reaction = begin
          CommentReaction.find_or_create_by!(
            comment: @original_comment,
            user: @agent,
            emoji: "✅"
          )
        rescue ActiveRecord::RecordNotUnique
          CommentReaction.find_by(comment: @original_comment, user: @agent, emoji: "✅")
        end

        CommentReaction.broadcast_reaction_update(@original_comment) if reaction
      rescue StandardError => e
        Rails.logger.warn("[AiAgent::ReviewHandler] Failed to add review reaction: #{e.message}")
      end
    end
  end
end
