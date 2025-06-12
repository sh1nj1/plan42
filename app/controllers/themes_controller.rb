class ThemesController < ApplicationController
  allow_unauthenticated_access only: :update

  def update
    theme = params[:theme].to_s
    theme = "light" unless %w[light dark].include?(theme)
    cookies.permanent[:theme] = theme
    Current.user&.update(theme: theme)
    Current.theme = theme
    head :ok
  end
end
