module Collavre
  module Comments
    class CommandProcessor
      # Every command matches against the stripped content with a leading "/"
      # (e.g. /\A\/topic\b/), so anything else can never be a command. Bail out
      # before building the handlers: the MCP tool list alone costs several
      # milliseconds per plain comment (plus a query when its cache is cold).
      COMMAND_PREFIX = "/".freeze

      def initialize(comment:, user:)
        @comment = comment
        @user = user
      end

      def call
        return unless command_candidate?

        command_handlers.each do |command|
          result = command.call
          return result if result.present?
        end
        nil
      rescue StandardError => e
        Rails.logger.error("Comment command processing failed: #{e.message}")
        e.message
      end

      private

      attr_reader :comment, :user

      def command_candidate?
        comment.content.to_s.strip.start_with?(COMMAND_PREFIX)
      end

      def command_handlers
        static_commands + mcp_commands
      end

      def static_commands
        [
          Collavre::Comments::CalendarCommand.new(comment: comment, user: user),
          Collavre::Comments::TopicCommand.new(comment: comment, user: user),
          Collavre::Comments::CompressCommand.new(comment: comment, user: user)
        ]
      end

      def mcp_commands
        Collavre::Comments::McpCommandBuilder.new(comment: comment, user: user, creative: comment.creative).commands
      end
    end
  end
end
