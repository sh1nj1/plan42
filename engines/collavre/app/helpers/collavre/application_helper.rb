module Collavre
  module ApplicationHelper
    # All Collavre engine stylesheets in load order.
    # Host apps should call <%= collavre_stylesheets %> in their layout <head>
    # instead of listing individual stylesheet_link_tags.
    COLLAVRE_STYLESHEETS = %w[
      collavre/design_tokens
      collavre/dark_mode
      collavre/creatives
      collavre/actiontext
      collavre/activity_logs
      collavre/user_menu
      collavre/org_chart
      collavre/popup
      collavre/comments_popup
      collavre/comment_versions
      collavre/mention_menu
      collavre/slide_view
    ].freeze

    COLLAVRE_PRINT_STYLESHEETS = %w[
      collavre/print
    ].freeze

    # Renders all Collavre engine stylesheet tags.
    # Call this once in the host app's layout <head> section.
    #
    #   <%= collavre_stylesheets %>
    #
    def collavre_stylesheets
      tags = COLLAVRE_STYLESHEETS.map do |sheet|
        stylesheet_link_tag(sheet)
      end
      tags += COLLAVRE_PRINT_STYLESHEETS.map do |sheet|
        stylesheet_link_tag(sheet, media: "print")
      end
      safe_join(tags, "\n    ")
    end

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

    # Renders CSS for admin-configured default themes (light/dark mode)
    # Only applies when the user has no personal theme set
    def default_theme_styles
      return "" if Current.user&.theme.present?

      light_theme = SystemSetting.default_light_theme
      dark_theme = SystemSetting.default_dark_theme
      return "" unless light_theme || dark_theme

      styles = []

      if light_theme
        styles << render_theme_media_query(light_theme, "light")
      end

      if dark_theme
        styles << render_theme_media_query(dark_theme, "dark")
      end

      # Safe: CSS generated from admin-configured theme settings (CSS variables only)
      styles.join("\n").html_safe # rubocop:disable Rails/OutputSafety
    end

    private

    def render_theme_media_query(theme, mode)
      vars = theme.variables.map { |k, v| "#{k}: #{v} !important;" }.join("\n            ")
      legacy = legacy_alias_declarations(theme.variables).map { |k, v| "#{k}: #{v} !important;" }.join("\n            ")
      dark_filter = theme.dark? ? "--date-icon-filter: invert(0.8) !important;" : ""

      <<~CSS
        @media (prefers-color-scheme: #{mode}) {
          body:not(.dark-mode):not(.light-mode) {
            #{vars}
            #{legacy}
            #{dark_filter}
          }
        }
      CSS
    end

    public

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
