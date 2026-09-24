# frozen_string_literal: true

module Collavre
  module AiAgent
    class ReplyPlaceholder
      def self.call(original_comment:, agent:, task:)
        return nil unless original_comment

        reply = nil
        # Serialize placeholder insertion with resend's reply snapshot and deletion.
        # The worker may have loaded its source before waiting for this lock.
        Comments::TopicMutation.call(original_comment.topic_id, original_comment.creative_id) do
          next unless Comment.exists?(id: original_comment.id, creative_id: original_comment.creative_id,
                                      topic_id: original_comment.topic_id)

          reply = original_comment.creative.comments.create!(
            content: Comment::STREAMING_PLACEHOLDER_CONTENT,
            user: agent,
            topic_id: original_comment.topic_id,
            task: task,
            skip_dispatch: true  # A2A routing handled by A2aDispatcher after finalization
          )
        end
        reply
      end
    end
  end
end
