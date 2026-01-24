module Collavre
  module Comments
    class McpCommandBuilder
      def initialize(comment:, user:, logger: Rails.logger)
        @comment = comment
        @user = user
        @logger = logger
      end

      def commands
        return [] unless defined?(RailsMcpEngine)

        RailsMcpEngine::Engine.build_tools!
        tools = meta_tool_service.call(action: "list", tool_name: nil, query: nil, arguments: nil)
        Array(tools[:tools]).map do |tool|
          McpCommand.new(comment: comment, user: user, tool: tool, meta_tool_service: meta_tool_service)
        end
      rescue StandardError => e
        logger.error("MCP command registration failed: #{e.message}")
        []
      end

      private

      attr_reader :comment, :user, :logger

      def meta_tool_service
        @meta_tool_service ||= Tools::MetaToolService.new
      end
    end
  end
end
