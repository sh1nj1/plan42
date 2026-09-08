module Collavre
  module CreativeMoveHelper
    def render_creative_move_action(creative, can_write)
      return safe_join([]) if creative.archived? || !can_write

      button_tag(t("collavre.dnd.move_title"), type: "button", class: "creative-action-btn",
        data: { creative_move_id: creative.id }, aria: { haspopup: "dialog" })
    end
  end
end
