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
      [ CalendarCommand.new(comment: comment, user: user) ]
    end

    def mcp_commands
      McpCommandBuilder.new(comment: comment, user: user).commands
    end
  end
end
