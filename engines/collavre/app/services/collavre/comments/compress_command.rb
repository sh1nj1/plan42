module Collavre
  module Comments
    class CompressCommand
      COMMAND_PATTERN = /\A\/compress\b/i.freeze

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You are summarizing a conversation thread in a project management tool.
        Preserve key decisions, action items, important context, and any conclusions.
        Be concise but thorough. Respond in the same language as the conversation.
        Use markdown formatting for readability.
      PROMPT

      def initialize(comment:, user:)
        @comment = comment
        @user = user
        @creative = comment.creative
      end

      def call
        return unless compress_command?

        validate!
        enqueue_compress_job
      rescue StandardError => e
        Rails.logger.error("Compress command failed: #{e.message}")
        e.message
      end

      private

      attr_reader :comment, :user, :creative

      def compress_command?
        comment.content.to_s.strip.match?(COMMAND_PATTERN)
      end

      def extra_prompt
        content = comment.content.to_s.strip
        rest = content.sub(COMMAND_PATTERN, "").strip
        rest.presence
      end

      def validate!
        unless comment.topic_id.present?
          raise I18n.t("collavre.comments.compress_command.topic_required")
        end

        topic_comments = creative.comments.where(topic_id: comment.topic_id)
        if topic_comments.count <= 1 # only the /compress command itself
          raise I18n.t("collavre.comments.compress_command.nothing_to_compress")
        end
      end

      def enqueue_compress_job
        CompressJob.perform_later(
          creative.id,
          comment.topic_id,
          user.id,
          extra_prompt
        )
        I18n.t("collavre.comments.compress_command.started")
      end
    end
  end
end
