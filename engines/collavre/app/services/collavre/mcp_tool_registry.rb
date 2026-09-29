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

    # Preserve only assignments hidden by permissions, not stale or inactive tools.
    def self.permission_hidden_names(names, user)
      system = names & system_names.to_a
      restricted = system.reject { |name| user_permitted?(name, user) }
      dynamic = McpTool.active.where(name: names - system).includes(:creative)
      restricted + dynamic.filter_map do |tool|
        tool.name if tool.creative && !tool.creative.has_permission?(user, :write)
      end
    end

    # A system tool may restrict itself to specific users by defining
    # `self.allowed_user_emails` or a stronger `self.user_permitted?` identity check.
    # Tools without that declaration, and non-system tools, are unrestricted
    # here — dynamic tools are gated by creative permission elsewhere.
    def self.user_permitted?(name, user)
      service = ToolMeta.registry.find { |klass| klass.tool_metadata[:name] == name }
      return service.user_permitted?(user) if service.respond_to?(:user_permitted?)
      return true unless service.respond_to?(:allowed_user_emails)

      user.present? && service.allowed_user_emails.include?(user.email)
    end
  end
end
