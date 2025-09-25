class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :switch_locale
  around_action :set_time_zone

  def switch_locale(&action)
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

    redirect_to root_path, alert: t("users.admin_required")
  end
end
