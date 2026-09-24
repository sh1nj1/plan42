# frozen_string_literal: true

module Collavre
  # Read names from DSL metadata without rebuilding parameter schemas.
  class McpToolRegistry
    def self.names
      ToolMeta.registry.map { |service| service.tool_metadata[:name] }.to_set
    end

    def self.system_names
      ToolMeta.registry.filter_map do |service|
        service.tool_metadata[:name] unless service.instance_variable_get(McpToolRegistrar::OWNER_IVAR)
      end.to_set
    end
  end
end
