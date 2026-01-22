class ApplicationController < ActionController::Base
  before_action :verify_cloudfront_origin!
  include Authentication
  include DynamicRateLimiting
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :switch_locale
  around_action :set_time_zone



  require "set"

  def switch_locale(&action)
    resume_session
    locale = normalize_supported_locale(Current.user&.locale) ||
             normalize_supported_locale(params[:locale]) ||
             extract_locale_from_accept_language_header ||
             I18n.default_locale.to_s

    if Current.user && Current.user.locale.blank?
      detected = extract_locale_from_accept_language_header || I18n.default_locale.to_s
      Current.user.update(locale: detected)
    end

    I18n.with_locale(locale, &action)
  end

  private

  helper_method :auth_provider_enabled? # Make available to views

  def auth_provider_enabled?(key)
    @disabled_auth_providers_set ||= begin
      setting = SystemSetting.find_by(key: "auth_providers_disabled")
      if setting
        setting.value.split(",").to_set
      else
        Set.new # Default: none disabled
      end
    end

    !@disabled_auth_providers_set.include?(key.to_s)
  end

  def enforce_auth_provider!(key)
    return if auth_provider_enabled?(key)

    redirect_to collavre.new_session_path, alert: I18n.t("users.sessions.new.provider_disabled")
  end

  def verify_cloudfront_origin!
    return if skip_cloudfront_verification?

    unless request.headers["X-Origin-Secret"] == ENV["ORIGIN_SHARED_SECRET"]
      head :forbidden
    end
  end

  def skip_cloudfront_verification?
    return false if request.headers["X-Origin-Secret"].present?
    return true if ENV["ORIGIN_SHARED_SECRET"].blank?

    # health checks, internal callbacks, etc.
    request.path.start_with?("/up") || request.path.start_with?("/health")
  end

  def extract_locale_from_accept_language_header
    header = request.env["HTTP_ACCEPT_LANGUAGE"]&.split(",")&.first
    normalize_supported_locale(header)
  end

  def normalize_supported_locale(locale)
    normalized = locale.to_s.split("-").first
    available = I18n.available_locales.map(&:to_s)
    available.include?(normalized) ? normalized : nil
  end

  def set_time_zone(&action)
    resume_session
    zone = Current.user&.timezone
    zone.present? ? Time.use_zone(zone, &action) : action.call
  end

  def require_system_admin!
    return if Current.user&.system_admin?

    render file: "public/404.html", status: :not_found, layout: false
  end
end
