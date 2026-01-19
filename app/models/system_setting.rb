class SystemSetting < ApplicationRecord
  # Default values for account lockout
  DEFAULT_MAX_LOGIN_ATTEMPTS = 5
  DEFAULT_LOCKOUT_DURATION_MINUTES = 30

  validates :key, presence: true, uniqueness: true

  def self.help_menu_link
    find_by(key: "help_menu_link")&.value
  end

  def self.mcp_tool_approval_required?
    if Current.mcp_tool_approval_required.nil?
      Current.mcp_tool_approval_required = find_by(key: "mcp_tool_approval_required")&.value == "true"
    end
    Current.mcp_tool_approval_required
  end

  # Account lockout settings
  def self.max_login_attempts
    find_by(key: "max_login_attempts")&.value&.to_i || DEFAULT_MAX_LOGIN_ATTEMPTS
  end

  def self.lockout_duration_minutes
    find_by(key: "lockout_duration_minutes")&.value&.to_i || DEFAULT_LOCKOUT_DURATION_MINUTES
  end

  def self.lockout_duration
    lockout_duration_minutes.minutes
  end
end
