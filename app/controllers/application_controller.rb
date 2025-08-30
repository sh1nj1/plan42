class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :switch_locale
  around_action :set_time_zone

  def switch_locale(&action)
    locale = Current.user&.locale ||
             params[:locale] ||
             extract_locale_from_accept_language_header ||
             "en-US"
    I18n.with_locale(normalize_locale(locale), &action)
  end

  private

  def extract_locale_from_accept_language_header
    request.env["HTTP_ACCEPT_LANGUAGE"]&.split(",")&.first
  end

  def normalize_locale(locale)
    locale.to_s.split("-").first
  end

  def set_time_zone(&action)
    resume_session
    zone = Current.user&.timezone
    zone.present? ? Time.use_zone(zone, &action) : action.call
  end
end
