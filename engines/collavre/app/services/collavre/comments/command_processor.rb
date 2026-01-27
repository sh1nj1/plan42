module Collavre
  module Comments
    class CommandProcessor
      def initialize(comment:, user:)
        @comment = comment
        @user = user
      end

      def call
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

      def command_handlers
        static_commands + mcp_commands
      end

      def static_commands
        [ Collavre::Comments::CalendarCommand.new(comment: comment, user: user) ]
      end

      def mcp_commands
        Collavre::Comments::McpCommandBuilder.new(comment: comment, user: user).commands
      end
    end
  end
end
