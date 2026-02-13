module Collavre
  module ApplicationHelper
    # Returns the body CSS class for the current user's theme.
    # Custom themes get "light-mode" to disable OS dark mode overrides,
    # ensuring the custom theme controls all colors regardless of OS setting.
    def body_theme_class
      theme = Current.user&.theme.presence || SystemSetting.default_theme
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

    # Maps semantic token names to their legacy alias names.
    # When custom themes inject semantic tokens on <body>, the legacy aliases
    # defined on :root still resolve to :root's light values. This map lets
    # the theme injection template also emit legacy aliases so that CSS using
    # old variable names (e.g. --color-section-bg) picks up custom values.
    SEMANTIC_TO_LEGACY = {
      "--surface-bg" => "--color-bg",
      "--surface-nav" => "--color-nav-bg",
      "--surface-section" => "--color-section-bg",
      "--surface-input" => "--color-input-bg",
      "--surface-btn" => "--color-btn-bg",
      "--surface-secondary" => "--color-secondary-background",
      "--text-primary" => "--color-text",
      "--text-muted" => "--color-muted",
      "--text-on-btn" => "--color-btn-text",
      "--text-nav" => "--color-nav-text",
      "--text-nav-btn" => "--color-nav-btn-text",
      "--text-chat-btn" => "--color-chat-btn-text",
      "--text-on-badge" => "--color-badge-text",
      "--text-input" => "--color-input-text",
      "--color-brand" => "--color-complete",
      "--color-active" => "--color-secondary-active",
      "--border-color" => "--color-border",
      "--border-drag-over" => "--color-drag-over",
      "--border-drag-edge" => "--color-drag-over-edge"
    }.freeze

    # Given a hash of semantic token variables, returns additional legacy
    # alias declarations so old CSS picks up the custom theme values.
    def legacy_alias_declarations(variables)
      aliases = {}
      variables.each do |key, value|
        if (legacy_name = SEMANTIC_TO_LEGACY[key])
          aliases[legacy_name] = value
        end
      end
      aliases
    end
  end
end
