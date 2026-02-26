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
        authorize!
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

        # The /compress command comment may not be saved yet, so count existing non-compress comments
        compress_pattern = /\A\/compress\b/i
        existing_count = creative.comments.where(topic_id: comment.topic_id)
          .reject { |c| c.content.to_s.strip.match?(compress_pattern) }.size
        if existing_count < 2
          raise I18n.t("collavre.comments.compress_command.nothing_to_compress")
        end
      end

      def authorize!
        unless creative.has_permission?(user, :write)
          raise I18n.t("collavre.comments.compress_command.not_authorized")
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
