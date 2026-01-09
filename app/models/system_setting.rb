class SystemSetting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  def self.help_menu_link
    find_by(key: "help_menu_link")&.value
  end

  def self.mcp_tool_approval_required?
    find_by(key: "mcp_tool_approval_required")&.value == "true"
  end
end
