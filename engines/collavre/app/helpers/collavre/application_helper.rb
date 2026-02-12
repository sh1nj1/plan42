module Collavre
  module ApplicationHelper
    # Returns the body CSS class for the current user's theme.
    # Custom themes get "light-mode" to disable OS dark mode overrides,
    # ensuring the custom theme controls all colors regardless of OS setting.
    def body_theme_class
      theme = Current.user&.theme
      return "" if theme.blank?

      case theme
      when "dark"
        "dark-mode"
      when "light"
        "light-mode"
      else
        "light-mode" # Custom theme: neutralize OS dark mode
      end
    end
  end
end
