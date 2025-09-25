module Comments
  class CommandProcessor
    COMMANDS = [ CalendarCommand ].freeze

    def initialize(comment:, user:)
      @comment = comment
      @user = user
    end

    def call
      COMMANDS.each do |command_class|
        result = command_class.new(comment: comment, user: user).call
        return result if result.present?
      end
      nil
    rescue StandardError => e
      Rails.logger.error("Comment command processing failed: #{e.message}")
      e.message
    end

    private

    attr_reader :comment, :user
  end
end
