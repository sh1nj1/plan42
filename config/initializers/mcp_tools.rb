Rails.application.config.to_prepare do
  begin
    if ActiveRecord::Base.connection.table_exists?(:mcp_tools)
      McpService.load_active_tools
    end
  rescue ActiveRecord::NoDatabaseError, PG::ConnectionBad
    # Ignore database errors during initialization (e.g. assets:precompile)
  end
rescue => e
  Rails.logger.error("Failed to load MCP tools: #{e.message}")
end
