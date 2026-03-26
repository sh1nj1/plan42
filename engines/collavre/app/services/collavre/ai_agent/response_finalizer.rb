# frozen_string_literal: true

module Collavre
  module AiAgent
    # Handles finalization of AI agent responses:
    # - Review workflow processing
    # - Comment creation/update
    # - Activity log reassociation
    class ResponseFinalizer
      def initialize(task:, agent:, original_comment:, reply_comment:, response_content:)
        @task = task
        @agent = agent
        @original_comment = original_comment
        @reply_comment = reply_comment
        @response_content = response_content
      end

      # Whether the last finalization was a review-flow update (no new comment created)
      attr_reader :review_flow

      # Finalize the response, handling review workflow if applicable
      # Returns the finalized comment or nil
      def finalize
        @review_flow = false
        # If no content, destroy placeholder and return
        if @response_content.blank?
          @reply_comment&.destroy!
          return nil
        end

        review_handler = ReviewHandler.new(@original_comment, @agent)

        if @reply_comment
          finalize_reply_comment(review_handler)
        elsif @original_comment
          create_reply_comment
        end
      end

      private

      def finalize_reply_comment(review_handler)
        if @original_comment&.review_message? && review_handler.handle(@response_content, task: @task)
          # Review workflow: update quoted comment in place (no new comment created)
          @review_flow = true
          review_handler.add_completion_reaction
          reassociate_activity_logs(@reply_comment, @original_comment.quoted_comment)
          @reply_comment.destroy!
          @original_comment.quoted_comment
        else
          # Normal comment workflow
          update_reply_comment
          reassociate_activity_logs(@original_comment, @reply_comment)
          @reply_comment
        end
      end

      def update_reply_comment
        @reply_comment.content_will_change!
        @reply_comment.update!(content: @response_content)
        @reply_comment.broadcast_update_to(
          [ @reply_comment.creative, :comments ],
          partial: "collavre/comments/comment",
          locals: { comment: @reply_comment, streaming: false }
        )

        log_action("reply_created", { comment_id: @reply_comment.id, content: @response_content })
        @reply_comment.notify_ai_completion
      end

      def create_reply_comment
        reply_comment = @original_comment.creative.comments.create!(
          content: @response_content,
          user: @agent,
          topic_id: @original_comment.topic_id
        )

        log_action("reply_created", { comment_id: reply_comment.id, content: @response_content })
        reassociate_activity_logs(@original_comment, reply_comment)
        reply_comment
      end

      def reassociate_activity_logs(from_comment, to_comment)
        ActivityLog.where(comment: from_comment, user: @agent)
                   .update_all(comment_id: to_comment.id)
      end

      def log_action(type, payload, result = nil)
        @task.task_actions.create!(
          action_type: type,
          payload: payload,
          result: result,
          status: "done"
        )
      end
    end
  end
end
