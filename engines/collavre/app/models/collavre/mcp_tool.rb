module Collavre
  class McpTool < ApplicationRecord
    self.table_name = "mcp_tools"

    belongs_to :creative, class_name: "Collavre::Creative"

    validates :name, presence: true, uniqueness: true
    validates :source_code, presence: true

    after_destroy :unregister_tool

    scope :active, -> { where.not(approved_at: nil) }

    def active?
      approved_at.present?
    end

    def approve!
      # Register the tool immediately upon approval
      ::McpService.register_tool_from_source(source_code)
      update!(approved_at: Time.current)
    end

    private

    def unregister_tool
      ::McpService.delete_tool(name)
    end
  end
end
