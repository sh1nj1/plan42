module Collavre
  module CreativeMoveHelper
    def render_creative_move_action(creative, can_write)
      # Signed-out visitors reach public creatives through the unauthenticated
      # index/show actions. They cannot move and cannot link either, since
      # link_drop requires a session, so the menu would only ever redirect them
      # to sign-in. The comment action hides itself the same way.
      return safe_join([]) if creative.archived? || Current.user.nil?

      # Every row carries this button, so the visible "Move…" label alone would
      # give a screen reader dozens of identically named controls. The snippet
      # is the same 24-character label the comment button already renders.
      button_tag(t("collavre.dnd.move_title"), type: "button", class: "creative-action-btn",
        data: { creative_move_id: creative.id, creative_move_writable: can_write },
        aria: { haspopup: "dialog",
                label: t("collavre.dnd.move_creative", title: creative.creative_snippet) })
    end
  end
end
