class SystemSetting < ApplicationRecord
  # Default values for account lockout
  DEFAULT_MAX_LOGIN_ATTEMPTS = 5
  DEFAULT_LOCKOUT_DURATION_MINUTES = 30

  # Default values for session timeout (in minutes, 0 = no timeout)
  DEFAULT_SESSION_TIMEOUT_MINUTES = 0

  # Default values for rate limiting
  DEFAULT_PASSWORD_RESET_RATE_LIMIT = 5
  DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES = 60
  DEFAULT_API_RATE_LIMIT = 100
  DEFAULT_API_RATE_PERIOD_MINUTES = 1

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

  # Session timeout settings
  def self.session_timeout_minutes
    find_by(key: "session_timeout_minutes")&.value&.to_i || DEFAULT_SESSION_TIMEOUT_MINUTES
  end

  def self.session_timeout_enabled?
    session_timeout_minutes > 0
  end

  def self.session_timeout
    session_timeout_minutes.minutes
  end

  # Rate limiting settings - Password Reset
  def self.password_reset_rate_limit
    find_by(key: "password_reset_rate_limit")&.value&.to_i || DEFAULT_PASSWORD_RESET_RATE_LIMIT
  end

  def self.password_reset_rate_period_minutes
    find_by(key: "password_reset_rate_period_minutes")&.value&.to_i || DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES
  end

  def self.password_reset_rate_period
    password_reset_rate_period_minutes.minutes
  end

  # Rate limiting settings - API
  def self.api_rate_limit
    find_by(key: "api_rate_limit")&.value&.to_i || DEFAULT_API_RATE_LIMIT
  end

  def self.api_rate_period_minutes
    find_by(key: "api_rate_period_minutes")&.value&.to_i || DEFAULT_API_RATE_PERIOD_MINUTES
  end

  def self.api_rate_period
    api_rate_period_minutes.minutes
  end
end
