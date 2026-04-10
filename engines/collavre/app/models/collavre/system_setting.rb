module Collavre
  class SystemSetting < ApplicationRecord
    self.table_name = "system_settings"

    # Cache expiry time for settings
    CACHE_EXPIRY = 5.minutes

    # Default values for account lockout
    DEFAULT_MAX_LOGIN_ATTEMPTS = 5
    DEFAULT_LOCKOUT_DURATION_MINUTES = 30

    # Default values for session timeout (in minutes, 0 = no timeout)
    DEFAULT_SESSION_TIMEOUT_MINUTES = 0

    # Default values for password policy
    DEFAULT_PASSWORD_MIN_LENGTH = 8

    # Default values for rate limiting
    DEFAULT_PASSWORD_RESET_RATE_LIMIT = 5
    DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES = 60
    DEFAULT_API_RATE_LIMIT = 100
    DEFAULT_API_RATE_PERIOD_MINUTES = 1

    # Default values for creatives access
    # By default, public access is allowed (false)
    DEFAULT_CREATIVES_LOGIN_REQUIRED = false

    # Default home page path (nil means use root_path "/")
    DEFAULT_HOME_PAGE_PATH = nil

    # Default theme IDs (nil means use built-in light/dark)
    # These reference UserTheme IDs for admin-configured custom themes
    DEFAULT_LIGHT_THEME_ID = nil
    DEFAULT_DARK_THEME_ID = nil

    # Default LLM request timeout (seconds)
    DEFAULT_LLM_REQUEST_TIMEOUT_SECONDS = 1800

    # Default creative display settings (system-wide)
    DEFAULT_DISPLAY_LEVEL = 6
    DEFAULT_COMPLETION_MARK = ""

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
        lockout_duration_minutes session_timeout_minutes password_min_length
        password_reset_rate_limit password_reset_rate_period_minutes
        api_rate_limit api_rate_period_minutes auth_providers_disabled
        creatives_login_required home_page_path default_light_theme_id default_dark_theme_id
        display_level completion_mark llm_request_timeout_seconds
      ].each { |k| Rails.cache.delete("system_setting:#{k}") }
    end

    private

    def clear_cache
      Rails.cache.delete("system_setting:#{key}")
      # If key was changed, well also clear the old key's cache entry
      if saved_change_to_key?
        old_key = saved_change_to_key.first
        Rails.cache.delete("system_setting:#{old_key}") if old_key.present?
      end
    end

    def self.help_menu_link
      cached_value("help_menu_link")
    end

    def self.creatives_login_required?
      cached_value("creatives_login_required", DEFAULT_CREATIVES_LOGIN_REQUIRED.to_s) == "true"
    end

    def self.home_page_path
      value = cached_value("home_page_path")
      value.presence
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

    # Password policy settings (capped at 72 due to bcrypt limit)
    def self.password_min_length
      value = cached_value("password_min_length")&.to_i
      value = DEFAULT_PASSWORD_MIN_LENGTH if value.nil? || value < 1
      [ value, 72 ].min
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

    # Default theme IDs for users without a personal theme preference
    def self.default_light_theme_id
      value = cached_value("default_light_theme_id")
      value.present? && value.to_i.positive? ? value.to_i : nil
    end

    def self.default_dark_theme_id
      value = cached_value("default_dark_theme_id")
      value.present? && value.to_i.positive? ? value.to_i : nil
    end

    def self.default_light_theme
      id = default_light_theme_id
      id ? Collavre::UserTheme.find_by(id: id) : nil
    end

    def self.default_dark_theme
      id = default_dark_theme_id
      id ? Collavre::UserTheme.find_by(id: id) : nil
    end

    # Creative display settings (system-wide)
    def self.display_level
      cached_value("display_level")&.to_i || DEFAULT_DISPLAY_LEVEL
    end

    def self.completion_mark
      value = cached_value("completion_mark")
      value.nil? ? DEFAULT_COMPLETION_MARK : value
    end

    # LLM request timeout (seconds)
    def self.llm_request_timeout_seconds
      value = cached_value("llm_request_timeout_seconds")&.to_i
      value.nil? || value < 30 ? DEFAULT_LLM_REQUEST_TIMEOUT_SECONDS : value
    end
  end
end
