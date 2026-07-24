module Collavre
  class CommandMenuComponent < AutocompletePopupComponent
    def initialize(menu_id: "command-menu")
      super(menu_id: menu_id, extra_classes: nil)
    end

    def form_submit_label
      I18n.t("collavre.comments.command_menu.form_submit")
    end

    def form_cancel_label
      I18n.t("collavre.comments.command_menu.form_cancel")
    end
  end
end
