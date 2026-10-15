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
        options = parse_options(text)
        return message(options) if options.is_a?(String)

        text = text.strip
        agent = leading_agent(text)
        return message("agent_not_authorized") unless valid_agent_selection?(text, agent)

        text = text.sub(/\A@#{Regexp.escape(agent.name)}:\s*/i, "") if agent
        prepare_loop(text.sub(/\A--(?:\s|\z)/, ""), agent, options)
        nil
      end

      private

      def parse_options(text)
        options = { "max" => "10", "cooldown" => "10" }
        while (match = text.match(/\A--(max|cooldown)(?=\s|\z)/))
          name = match[1]
          text.slice!(0, match[0].length)
          value = text.slice!(/\A\s+\S+/).to_s.strip
          valid = name == "max" ? value.match?(/\A[1-9]\d*\z/) && value.to_i <= 1000 :
            value.match?(/\A\d+\z/) && value.to_i <= 3600
          return "invalid_#{name}" unless valid

          options[name] = value
          text.strip!
        end
        options
      end

      def dispatch_suppressed?
        @comment.creative.inbox? && @comment.topic&.name == Creative::SYSTEM_TOPIC_NAME
      end

      def valid_agent_selection?(text, agent)
        return !text.match?(/\A@[^:\n]+:/) unless agent

        @comment.creative.has_permission?(agent, :feedback)
      end

      def leading_agent(text)
        @comment.mentioned_users.select(&:ai_user?).find do |user|
          text.match?(/\A@#{Regexp.escape(user.name)}:/i)
        end
      end

      def prepare_loop(text, agent, options)
        @comment.assign_attributes(quoted_comment: nil, review_type: nil)
        @comment.topic ||= @comment.creative.main_topic
        @comment.keep_loop_options = { "goal" => text.strip, "agent_id" => agent&.id,
                                       "max_iterations" => options.fetch("max").to_i,
                                       "cooldown_seconds" => options.fetch("cooldown").to_i }
        @comment.content = [ ("@#{agent.name}:" if agent), text.strip,
                             I18n.t("collavre.trigger_loop.instructions") ].compact.join("\n\n")
      end

      def message(key)
        I18n.t("collavre.comments.keep_command.#{key}")
      end
    end
  end
end
