# frozen_string_literal: true

module Collavre
  module Admin
    class SettingsController < ApplicationController
      before_action :require_system_admin!

      def index
        @help_link = SystemSetting.find_by(key: "help_menu_link")&.value
        @mcp_tool_approval = SystemSetting.find_by(key: "mcp_tool_approval_required")&.value == "true"
        @creatives_login_required = SystemSetting.creatives_login_required?
        @home_page_path = SystemSetting.home_page_path
        @home_page_path_authenticated = SystemSetting.home_page_path_authenticated

        # Account lockout settings
        @max_login_attempts = SystemSetting.max_login_attempts
        @lockout_duration_minutes = SystemSetting.lockout_duration_minutes

        # Password policy settings
        @password_min_length = SystemSetting.password_min_length

        # Session timeout settings
        @session_timeout_minutes = SystemSetting.session_timeout_minutes

        # LLM settings
        @llm_request_timeout_seconds = SystemSetting.llm_request_timeout_seconds
        @ai_agent_turn_deadline_seconds = SystemSetting.ai_agent_turn_deadline_seconds
        load_creative_history_settings

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

      def uiux
        @default_light_theme_id = SystemSetting.default_light_theme_id
        @default_dark_theme_id = SystemSetting.default_dark_theme_id
        @available_themes = Collavre::UserTheme.all.order(:name)
        @display_level = SystemSetting.display_level
        @completion_mark = SystemSetting.completion_mark
      end

      def update_uiux
        SystemSetting.transaction do
          light_theme_id = params[:default_light_theme_id].to_s.strip
          light_theme_setting = SystemSetting.find_or_initialize_by(key: "default_light_theme_id")
          light_theme_setting.value = light_theme_id.present? ? light_theme_id : nil
          light_theme_setting.save!

          dark_theme_id = params[:default_dark_theme_id].to_s.strip
          dark_theme_setting = SystemSetting.find_or_initialize_by(key: "default_dark_theme_id")
          dark_theme_setting.value = dark_theme_id.present? ? dark_theme_id : nil
          dark_theme_setting.save!

          # Creative display settings
          dl = params[:display_level].to_i
          dl = SystemSetting::DEFAULT_DISPLAY_LEVEL if dl < 1
          SystemSetting.find_or_initialize_by(key: "display_level").tap { |s| s.value = dl.to_s; s.save! }

          cm = params[:completion_mark].to_s
          SystemSetting.find_or_initialize_by(key: "completion_mark").tap { |s| s.value = cm; s.save! }
        end

        redirect_to collavre.admin_uiux_path, notice: t("admin.settings.updated")
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.record.errors.full_messages.join(", ")
        @default_light_theme_id = params[:default_light_theme_id]
        @default_dark_theme_id = params[:default_dark_theme_id]
        @available_themes = Collavre::UserTheme.all.order(:name)
        @display_level = params[:display_level].to_i.positive? ? params[:display_level].to_i : SystemSetting::DEFAULT_DISPLAY_LEVEL
        @completion_mark = params[:completion_mark].to_s
        render :uiux, status: :unprocessable_entity
      end

      def update
        SystemSetting.transaction do
          settings_from_params.each do |key, value|
            SystemSetting.find_or_initialize_by(key: key).update!(value: value)
          end

          # Home Page Paths (unauthenticated default + authenticated override).
          # Kept separate because they validate/normalize and may raise.
          save_home_page_path("home_page_path", params[:home_page_path])
          save_home_page_path("home_page_path_authenticated", params[:home_page_path_authenticated])

          save_auth_providers!
        end

        redirect_to collavre.admin_settings_path, notice: t("admin.settings.updated")
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.record.errors.full_messages.join(", ")
        restore_form_state
        render :index, status: :unprocessable_entity
      end

      private

      def restore_form_state
        restore_access_form_state
        restore_security_form_state
        restore_rate_limit_form_state
        restore_llm_form_state
      end

      def restore_access_form_state
        @help_link = params[:help_link]
        @mcp_tool_approval = params[:mcp_tool_approval] == "1"
        @creatives_login_required = params[:creatives_login_required] == "1"
        @home_page_path = params[:home_page_path]
        @home_page_path_authenticated = params[:home_page_path_authenticated]
        @enabled_auth_providers = params[:auth_providers] || []
      end

      def restore_security_form_state
        @max_login_attempts = params[:max_login_attempts].to_i.positive? ? params[:max_login_attempts].to_i : SystemSetting::DEFAULT_MAX_LOGIN_ATTEMPTS
        @lockout_duration_minutes = params[:lockout_duration_minutes].to_i.positive? ? params[:lockout_duration_minutes].to_i : SystemSetting::DEFAULT_LOCKOUT_DURATION_MINUTES
        @password_min_length = [ [ params[:password_min_length].to_i, SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH ].max, 72 ].min
        @session_timeout_minutes = [ params[:session_timeout_minutes].to_i, 0 ].max
      end

      def restore_rate_limit_form_state
        @password_reset_rate_limit = params[:password_reset_rate_limit].to_i.positive? ? params[:password_reset_rate_limit].to_i : SystemSetting::DEFAULT_PASSWORD_RESET_RATE_LIMIT
        @password_reset_rate_period_minutes = params[:password_reset_rate_period_minutes].to_i.positive? ? params[:password_reset_rate_period_minutes].to_i : SystemSetting::DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES
        @api_rate_limit = params[:api_rate_limit].to_i.positive? ? params[:api_rate_limit].to_i : SystemSetting::DEFAULT_API_RATE_LIMIT
        @api_rate_period_minutes = params[:api_rate_period_minutes].to_i.positive? ? params[:api_rate_period_minutes].to_i : SystemSetting::DEFAULT_API_RATE_PERIOD_MINUTES
      end

      def restore_llm_form_state
        @llm_request_timeout_seconds = params[:llm_request_timeout_seconds].to_i.positive? ? params[:llm_request_timeout_seconds].to_i : SystemSetting::DEFAULT_LLM_REQUEST_TIMEOUT_SECONDS
        @ai_agent_turn_deadline_seconds = params[:ai_agent_turn_deadline_seconds].to_i.positive? ? params[:ai_agent_turn_deadline_seconds].to_i : SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS
        @creative_history_retention_count = int_setting_value(
          :creative_history_retention_count,
          SystemSetting::DEFAULT_CREATIVE_HISTORY_RETENTION_COUNT,
          min: SystemSetting::MIN_CREATIVE_HISTORY_RETENTION_COUNT
        )
        @creative_history_retention_days = int_setting_value(
          :creative_history_retention_days,
          SystemSetting::DEFAULT_CREATIVE_HISTORY_RETENTION_DAYS,
          min: SystemSetting::MIN_CREATIVE_HISTORY_RETENTION_DAYS
        )
      end

      def load_creative_history_settings
        @creative_history_retention_count = SystemSetting.creative_history_retention_count
        @creative_history_retention_days = SystemSetting.creative_history_retention_days
      end

      # Maps each SystemSetting key to its normalized string value derived from
      # the request params. Collapses the previously repetitive per-setting
      # blocks into a single data-driven loop in #update.
      def settings_from_params
        {
          "help_menu_link" => params[:help_link].to_s.strip,
          "mcp_tool_approval_required" => boolean_setting(:mcp_tool_approval),
          "creatives_login_required" => boolean_setting(:creatives_login_required),
          "max_login_attempts" => int_setting(:max_login_attempts, SystemSetting::DEFAULT_MAX_LOGIN_ATTEMPTS),
          "lockout_duration_minutes" => int_setting(:lockout_duration_minutes, SystemSetting::DEFAULT_LOCKOUT_DURATION_MINUTES),
          "password_min_length" => [ [ params[:password_min_length].to_i, SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH ].max, 72 ].min.to_s,
          "session_timeout_minutes" => [ params[:session_timeout_minutes].to_i, 0 ].max.to_s,
          "password_reset_rate_limit" => int_setting(:password_reset_rate_limit, SystemSetting::DEFAULT_PASSWORD_RESET_RATE_LIMIT),
          "password_reset_rate_period_minutes" => int_setting(:password_reset_rate_period_minutes, SystemSetting::DEFAULT_PASSWORD_RESET_RATE_PERIOD_MINUTES),
          "api_rate_limit" => int_setting(:api_rate_limit, SystemSetting::DEFAULT_API_RATE_LIMIT),
          "api_rate_period_minutes" => int_setting(:api_rate_period_minutes, SystemSetting::DEFAULT_API_RATE_PERIOD_MINUTES),
          "llm_request_timeout_seconds" => int_setting(:llm_request_timeout_seconds, SystemSetting::DEFAULT_LLM_REQUEST_TIMEOUT_SECONDS, min: 30),
          "ai_agent_turn_deadline_seconds" => int_setting(:ai_agent_turn_deadline_seconds, SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS, min: 60),
          "creative_history_retention_count" => int_setting(
            :creative_history_retention_count,
            SystemSetting::DEFAULT_CREATIVE_HISTORY_RETENTION_COUNT,
            min: SystemSetting::MIN_CREATIVE_HISTORY_RETENTION_COUNT
          ),
          "creative_history_retention_days" => int_setting(
            :creative_history_retention_days,
            SystemSetting::DEFAULT_CREATIVE_HISTORY_RETENTION_DAYS,
            min: SystemSetting::MIN_CREATIVE_HISTORY_RETENTION_DAYS
          )
        }
      end

      # Checkbox param ("1" when checked) -> "true"/"false" string value.
      def boolean_setting(param_key)
        params[param_key] == "1" ? "true" : "false"
      end

      # Integer param that falls back to a default when below the minimum floor.
      def int_setting(param_key, default, min: 1)
        int_setting_value(param_key, default, min: min).to_s
      end

      def int_setting_value(param_key, default, min: 1)
        value = params[param_key].to_i
        value = default if value < min
        value
      end

      def save_auth_providers!
        auth_providers = Array(params[:auth_providers]).reject(&:blank?)
        if auth_providers.empty?
          auth_setting = SystemSetting.new(key: "auth_providers_enabled")
          auth_setting.errors.add(:base, t("admin.settings.auth_provider_required"))
          raise ActiveRecord::RecordInvalid, auth_setting
        end

        all_provider_keys = Rails.application.config.auth_providers.map { |p| p[:key].to_s }
        disabled_providers = all_provider_keys - auth_providers
        SystemSetting.find_or_initialize_by(key: "auth_providers_disabled").update!(value: disabled_providers.join(","))
      end

      def save_home_page_path(key, raw_value)
        input = raw_value.to_s.strip
        setting = SystemSetting.find_or_initialize_by(key: key)
        if input.present?
          normalized_path, error = validate_and_normalize_home_page_path(input)
          if error
            stub = SystemSetting.new(key: key)
            stub.errors.add(:base, error)
            raise ActiveRecord::RecordInvalid, stub
          end
          setting.value = normalized_path
        else
          setting.value = nil
        end
        setting.save!
      end

      def validate_and_normalize_home_page_path(value)
        path = value.to_s.strip

        if path.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          return [ nil, t("admin.settings.home_page_path_invalid_url") ]
        end

        path = path.split(/[?#]/).first
        path = "/#{path}" unless path.start_with?("/")
        path = path.gsub(%r{/+}, "/")
        return [ nil, nil ] if path == "/"

        begin
          route_info = Rails.application.routes.recognize_path(path, method: :get)

          if route_info[:format].present? && route_info[:format] != "html"
            return [ nil, t("admin.settings.home_page_path_not_html", path: path) ]
          end

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
end
