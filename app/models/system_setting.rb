class SystemSetting < ApplicationRecord
  # Cache expiry time for settings
  CACHE_EXPIRY = 5.minutes

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

  # Clear cache after save
  after_commit :clear_cache

  # Cached setting retrieval
  def self.cached_value(key, default = nil)
    Rails.cache.fetch("system_setting:#{key}", expires_in: CACHE_EXPIRY) do
      find_by(key: key)&.value
    end || default
  end

  def self.clear_all_cache
    # Clear known setting keys
    %w[
      help_menu_link mcp_tool_approval_required max_login_attempts
      lockout_duration_minutes session_timeout_minutes
      password_reset_rate_limit password_reset_rate_period_minutes
      api_rate_limit api_rate_period_minutes auth_providers_disabled
    ].each { |k| Rails.cache.delete("system_setting:#{k}") }
  end

  private

  def clear_cache
    Rails.cache.delete("system_setting:#{key}")
  end

  def self.help_menu_link
    cached_value("help_menu_link")
  end

  def self.mcp_tool_approval_required?
    if Current.mcp_tool_approval_required.nil?
      Current.mcp_tool_approval_required = cached_value("mcp_tool_approval_required") == "true"
    end
    Current.mcp_tool_approval_required
  end

  # Account lockout settings
  def self.max_login_attempts
    cached_value("max_login_attempts")&.to_i || DEFAULT_MAX_LOGIN_ATTEMPTS
  end

  def self.lockout_duration_minutes
    cached_value("lockout_duration_minutes")&.to_i || DEFAULT_LOCKOUT_DURATION_MINUTES
  end

  def self.lockout_duration
    lockout_duration_minutes.minutes
  end

  # Session timeout settings
  def self.session_timeout_minutes
    cached_value("session_timeout_minutes")&.to_i || DEFAULT_SESSION_TIMEOUT_MINUTES
  end

  def self.session_timeout_enabled?
    session_timeout_minutes > 0
  end

  def self.session_timeout
    session_timeout_minutes.minutes
  end

  # Rate limiting settings - Password Reset
  def self.password_reset_rate_limit
    cached_value("password_reset_rate_limit")&.to_i || DEFAULT_PASSWORD_RESET_RATE_LIMIT
  end

  def self.password_reset_rate_period_minutes
    cached_value("password_reset_rate_period_minutes")&.to_i || DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES
  end

  def self.password_reset_rate_period
    password_reset_rate_period_minutes.minutes
  end

  # Rate limiting settings - API
  def self.api_rate_limit
    cached_value("api_rate_limit")&.to_i || DEFAULT_API_RATE_LIMIT
  end

  def self.api_rate_period_minutes
    cached_value("api_rate_period_minutes")&.to_i || DEFAULT_API_RATE_PERIOD_MINUTES
  end

  def self.api_rate_period
    api_rate_period_minutes.minutes
  end
end
