module Admin
  class SettingsController < ApplicationController
    before_action :require_system_admin!

    def index
      @help_link = SystemSetting.find_by(key: "help_menu_link")&.value
      @mcp_tool_approval = SystemSetting.find_by(key: "mcp_tool_approval_required")&.value == "true"
      @creatives_login_required = SystemSetting.creatives_login_required?
      @home_page_path = SystemSetting.home_page_path

      # Account lockout settings
      @max_login_attempts = SystemSetting.max_login_attempts
      @lockout_duration_minutes = SystemSetting.lockout_duration_minutes

      # Password policy settings
      @password_min_length = SystemSetting.password_min_length

      # Session timeout settings
      @session_timeout_minutes = SystemSetting.session_timeout_minutes

      # Rate limiting settings
      @password_reset_rate_limit = SystemSetting.password_reset_rate_limit
      @password_reset_rate_period_minutes = SystemSetting.password_reset_rate_period_minutes
      @api_rate_limit = SystemSetting.api_rate_limit
      @api_rate_period_minutes = SystemSetting.api_rate_period_minutes

      # Storage is "disabled" list. View expects "enabled" list.
      all_provider_keys = Rails.application.config.auth_providers.map { |p| p[:key].to_s }
      disabled_providers = SystemSetting.find_by(key: "auth_providers_disabled")&.value&.split(",") || []
      @enabled_auth_providers = all_provider_keys - disabled_providers
    end

    def update
      begin
        SystemSetting.transaction do
          # Help Link
          help_link_setting = SystemSetting.find_or_initialize_by(key: "help_menu_link")
          help_link_setting.value = params[:help_link].to_s.strip
          help_link_setting.save!

          # MCP Tool Approval
          mcp_setting = SystemSetting.find_or_initialize_by(key: "mcp_tool_approval_required")
          mcp_setting.value = params[:mcp_tool_approval] == "1" ? "true" : "false"
          mcp_setting.save!

          # Creatives Login Required
          creatives_login_setting = SystemSetting.find_or_initialize_by(key: "creatives_login_required")
          creatives_login_setting.value = params[:creatives_login_required] == "1" ? "true" : "false"
          creatives_login_setting.save!

          # Home Page Path (validate and normalize to clean absolute path)
          home_page_path_input = params[:home_page_path].to_s.strip
          if home_page_path_input.present?
            normalized_path, error = validate_and_normalize_home_page_path(home_page_path_input)
            if error
              home_page_setting = SystemSetting.new(key: "home_page_path")
              home_page_setting.errors.add(:base, error)
              raise ActiveRecord::RecordInvalid, home_page_setting
            end
            home_page_setting = SystemSetting.find_or_initialize_by(key: "home_page_path")
            home_page_setting.value = normalized_path
            home_page_setting.save!
          else
            home_page_setting = SystemSetting.find_or_initialize_by(key: "home_page_path")
            home_page_setting.value = nil
            home_page_setting.save!
          end

          # Account Lockout Settings
          max_attempts = params[:max_login_attempts].to_i
          max_attempts = SystemSetting::DEFAULT_MAX_LOGIN_ATTEMPTS if max_attempts < 1
          max_attempts_setting = SystemSetting.find_or_initialize_by(key: "max_login_attempts")
          max_attempts_setting.value = max_attempts.to_s
          max_attempts_setting.save!

          lockout_duration = params[:lockout_duration_minutes].to_i
          lockout_duration = SystemSetting::DEFAULT_LOCKOUT_DURATION_MINUTES if lockout_duration < 1
          lockout_setting = SystemSetting.find_or_initialize_by(key: "lockout_duration_minutes")
          lockout_setting.value = lockout_duration.to_s
          lockout_setting.save!

          # Password Policy Settings (floor at 8, capped at 72 due to bcrypt limit)
          password_min_length = params[:password_min_length].to_i
          password_min_length = [ password_min_length, SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH ].max
          password_min_length = [ password_min_length, 72 ].min
          password_min_length_setting = SystemSetting.find_or_initialize_by(key: "password_min_length")
          password_min_length_setting.value = password_min_length.to_s
          password_min_length_setting.save!

          # Session Timeout Settings
          session_timeout = params[:session_timeout_minutes].to_i
          session_timeout = 0 if session_timeout < 0
          session_timeout_setting = SystemSetting.find_or_initialize_by(key: "session_timeout_minutes")
          session_timeout_setting.value = session_timeout.to_s
          session_timeout_setting.save!

          # Rate Limiting - Password Reset
          pw_reset_limit = params[:password_reset_rate_limit].to_i
          pw_reset_limit = SystemSetting::DEFAULT_PASSWORD_RESET_RATE_LIMIT if pw_reset_limit < 1
          pw_reset_limit_setting = SystemSetting.find_or_initialize_by(key: "password_reset_rate_limit")
          pw_reset_limit_setting.value = pw_reset_limit.to_s
          pw_reset_limit_setting.save!

          pw_reset_period = params[:password_reset_rate_period_minutes].to_i
          pw_reset_period = SystemSetting::DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES if pw_reset_period < 1
          pw_reset_period_setting = SystemSetting.find_or_initialize_by(key: "password_reset_rate_period_minutes")
          pw_reset_period_setting.value = pw_reset_period.to_s
          pw_reset_period_setting.save!

          # Rate Limiting - API
          api_limit = params[:api_rate_limit].to_i
          api_limit = SystemSetting::DEFAULT_API_RATE_LIMIT if api_limit < 1
          api_limit_setting = SystemSetting.find_or_initialize_by(key: "api_rate_limit")
          api_limit_setting.value = api_limit.to_s
          api_limit_setting.save!

          api_period = params[:api_rate_period_minutes].to_i
          api_period = SystemSetting::DEFAULT_API_RATE_PERIOD_MINUTES if api_period < 1
          api_period_setting = SystemSetting.find_or_initialize_by(key: "api_rate_period_minutes")
          api_period_setting.value = api_period.to_s
          api_period_setting.save!

          # Auth Providers
          auth_providers = Array(params[:auth_providers]).reject(&:blank?)
          if auth_providers.empty?
            auth_setting = SystemSetting.new(key: "auth_providers_enabled") # Dummy for error
            auth_setting.errors.add(:base, t("admin.settings.auth_provider_required"))
            raise ActiveRecord::RecordInvalid, auth_setting
          end

          all_provider_keys = Rails.application.config.auth_providers.map { |p| p[:key].to_s }
          disabled_providers = all_provider_keys - auth_providers

          auth_setting = SystemSetting.find_or_initialize_by(key: "auth_providers_disabled")
          auth_setting.value = disabled_providers.join(",")
          auth_setting.save!
        end

        redirect_to admin_path, notice: t("admin.settings.updated")
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.record.errors.full_messages.join(", ")
        @help_link = params[:help_link]
        @mcp_tool_approval = params[:mcp_tool_approval] == "1"
        @creatives_login_required = params[:creatives_login_required] == "1"
        @home_page_path = params[:home_page_path]
        @max_login_attempts = params[:max_login_attempts].to_i.positive? ? params[:max_login_attempts].to_i : SystemSetting::DEFAULT_MAX_LOGIN_ATTEMPTS
        @lockout_duration_minutes = params[:lockout_duration_minutes].to_i.positive? ? params[:lockout_duration_minutes].to_i : SystemSetting::DEFAULT_LOCKOUT_DURATION_MINUTES
        @password_min_length = [ [ params[:password_min_length].to_i, SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH ].max, 72 ].min
        @session_timeout_minutes = [ params[:session_timeout_minutes].to_i, 0 ].max
        @password_reset_rate_limit = params[:password_reset_rate_limit].to_i.positive? ? params[:password_reset_rate_limit].to_i : SystemSetting::DEFAULT_PASSWORD_RESET_RATE_LIMIT
        @password_reset_rate_period_minutes = params[:password_reset_rate_period_minutes].to_i.positive? ? params[:password_reset_rate_period_minutes].to_i : SystemSetting::DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES
        @api_rate_limit = params[:api_rate_limit].to_i.positive? ? params[:api_rate_limit].to_i : SystemSetting::DEFAULT_API_RATE_LIMIT
        @api_rate_period_minutes = params[:api_rate_period_minutes].to_i.positive? ? params[:api_rate_period_minutes].to_i : SystemSetting::DEFAULT_API_RATE_PERIOD_MINUTES
        @enabled_auth_providers = params[:auth_providers] || []
        render :index, status: :unprocessable_entity
      end
    end

    private

    # Validate and normalize home page path to a clean absolute path
    # Returns [normalized_path, error_message]
    # - normalized_path is nil if path should use default behavior
    # - error_message is set if validation fails
    def validate_and_normalize_home_page_path(value)
      path = value.to_s.strip

      # Reject URLs with scheme (http://, https://, etc.)
      if path.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
        return [ nil, t("admin.settings.home_page_path_invalid_url") ]
      end

      # Extract path only (remove query string and fragment)
      path = path.split(/[?#]/).first

      # Ensure leading slash
      path = "/#{path}" unless path.start_with?("/")

      # Normalize multiple slashes
      path = path.gsub(%r{/+}, "/")

      # Return nil if path is just "/" (use default behavior)
      return [ nil, nil ] if path == "/"

      # Verify the path is routable via GET and serves HTML
      begin
        route_info = Rails.application.routes.recognize_path(path, method: :get)

        # Reject routes that don't serve HTML (e.g., API-only, service-worker)
        if route_info[:format].present? && route_info[:format] != "html"
          return [ nil, t("admin.settings.home_page_path_not_html", path: path) ]
        end

        # Reject known non-HTML paths
        non_html_paths = %w[/service-worker /manifest /up]
        if non_html_paths.any? { |p| path.start_with?(p) }
          return [ nil, t("admin.settings.home_page_path_not_html", path: path) ]
        end
      rescue ActionController::RoutingError
        return [ nil, t("admin.settings.home_page_path_not_routable", path: path) ]
      end

      [ path, nil ]
    end
  end
end
