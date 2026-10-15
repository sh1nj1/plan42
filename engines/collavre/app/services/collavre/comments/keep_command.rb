# frozen_string_literal: true

module Collavre
  module Comments
    class KeepCommand
      def initialize(comment:, user:)
        @comment = comment
        @user = user
      end

      def call
        return unless @comment.content.to_s.strip.match?(/\A\/keep\b/i)
        return message("private_not_supported") if @comment.private?
        return message("not_authorized") unless @comment.creative.has_permission?(@user, :write)

        return message("no_agent") if dispatch_suppressed?

        text = @comment.content.to_s.strip.sub(/\A\/keep\s*/i, "")
        limit = text.slice!(/\A--max(?:\s+\S+)?(?=\s|\z)/)&.split&.last || "10"
        return message("invalid_max") unless limit.match?(/\A[1-9]\d*\z/) && limit.to_i <= 50

        text = text.strip
        agent = leading_agent(text)
        return message("agent_not_authorized") if agent && !@comment.creative.has_permission?(agent, :feedback)

        text = text.sub(/\A@#{Regexp.escape(agent.name)}:\s*/i, "") if agent
        prepare_loop(text, agent, limit)
        nil
      end

      private

      def dispatch_suppressed?
        @comment.creative.inbox? && @comment.topic&.name == Creative::SYSTEM_TOPIC_NAME
      end

      def leading_agent(text)
        @comment.mentioned_users.select(&:ai_user?).find do |user|
          text.match?(/\A@#{Regexp.escape(user.name)}:/i)
        end
      end

      def prepare_loop(text, agent, limit)
        @comment.topic ||= @comment.creative.main_topic
        @comment.keep_loop_options = { "goal" => text.strip, "agent_id" => agent&.id,
                                       "max_iterations" => limit.to_i }
        @comment.content = [ ("@#{agent.name}:" if agent), text.strip,
                             I18n.t("collavre.trigger_loop.instructions") ].compact.join("\n\n")
      end

      def message(key)
        I18n.t("collavre.comments.keep_command.#{key}")
      end
    end
  end
end
