module Collavre
  # Engine stylesheet tags for host layouts.
  #
  # This lives in `lib/` rather than `app/helpers/` so the engine initializer can
  # mix it into `ActionView::Base` at boot: host apps that mount the gem without
  # including `Collavre::ApplicationHelper` still get `collavre_stylesheets` in
  # their own layouts and controller views.
  module StylesheetsHelper
    # All Collavre engine stylesheets in load order.
    # Host apps should call <%= collavre_stylesheets %> in their layout <head>
    # instead of listing individual stylesheet_link_tags.
    COLLAVRE_STYLESHEETS = %w[
      collavre/design_tokens
      collavre/dark_mode
      collavre/secret_fields
      collavre/gnb
      collavre/creatives
      collavre/workflow_editor
      collavre/actiontext
      collavre/activity_logs
      collavre/user_menu
      collavre/org_chart
      collavre/popup
      collavre/comments_popup
      collavre/workspace
      collavre/tables
      collavre/code_highlight
      collavre/comment_versions
      collavre/mention_menu
      collavre/modal_dialog
      collavre/slide_view
      collavre/image_lightbox
      collavre/search_popup
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
  end
end
