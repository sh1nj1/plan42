# frozen_string_literal: true

module Collavre
  # MetaToolService invokes services directly, bypassing FastMcp's list filter.
  # Reconcile process-local definitions before discovery or execution so another
  # worker's approval, edit, or deletion takes effect on the next meta call.
  class McpToolAccess
    def self.refresh
      active = McpTool.active.includes(:creative).index_by(&:name)
      ToolMeta.registry.dup.each do |service|
        name = service.instance_variable_get(McpToolRegistrar::OWNER_IVAR)
        next unless name
        next if active[name]&.source_code == service.instance_variable_get(:@collavre_mcp_source)

        McpService.delete_tool(name)
      end
      known_names = McpToolRegistry.names
      active.each_value { |tool| load_missing(tool, known_names) }
    end

    def self.load_missing(tool, known_names)
      return if known_names.include?(tool.name)

      McpService.register_tool_from_source(tool.source_code, expected_name: tool.name)
    rescue StandardError => e
      Rails.logger.error("Skipped MCP tool #{tool.name}: #{e.message}")
    end
    private_class_method :load_missing

    def self.allowed?(name)
      return true if McpToolRegistry.system_names.include?(name)

      tool = McpTool.find_by(name: name)
      return false unless tool&.active? && Current.user

      # Execution cannot wait for asynchronous share-cache invalidation.
      Creatives::PermissionChecker.current_allowed?(tool.creative_id, Current.user, :write)
    end
  end
end
