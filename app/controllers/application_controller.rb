class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :switch_locale
  before_action :set_current_theme

  def switch_locale(&action)
    locale = params[:locale] ||
             extract_locale_from_accept_language_header ||
             I18n.default_locale
    I18n.with_locale(locale, &action)
  end

  private

  def extract_locale_from_accept_language_header
    request.env["HTTP_ACCEPT_LANGUAGE"]&.scan(/^[a-z]{2}/)&.first
  end

  def set_current_theme
    theme = if Current.user&.theme.present?
               Current.user.theme
    else
               cookies[:theme]
    end
    Current.theme = theme.presence_in(%w[light dark]) || "light"
  end
end
