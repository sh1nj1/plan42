module Collavre
  module CreativeMoveHelper
    def render_creative_move_action(creative, can_write)
      return safe_join([]) if creative.archived? || !can_write

      # Every row carries this button, so the visible "Move…" label alone would
      # give a screen reader dozens of identically named controls. The snippet
      # is the same 24-character label the comment button already renders.
      button_tag(t("collavre.dnd.move_title"), type: "button", class: "creative-action-btn",
        data: { creative_move_id: creative.id },
        aria: { haspopup: "dialog",
                label: t("collavre.dnd.move_creative", title: creative.creative_snippet) })
    end
  end
end
