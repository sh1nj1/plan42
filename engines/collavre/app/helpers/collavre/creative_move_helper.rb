module Collavre
  module CreativeMoveHelper
    def render_creative_move_action(creative, can_write)
      return safe_join([]) if Current.user.nil?

      # Archived parents still expose selection for their active children.
      creative = nil if creative&.archived?

      button_tag(t("collavre.dnd.move_title"), type: "button", class: "popup-menu-item",
        data: { creative_move_id: creative&.id || "", creative_move_writable: can_write },
        aria: { haspopup: "dialog" })
    end
  end
end
