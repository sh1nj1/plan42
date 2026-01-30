module Collavre
  class UserMentionMenuComponent < AutocompletePopupComponent
    def initialize(menu_id: "mention-menu")
      super(menu_id: menu_id, extra_classes: "mention-popup")
    end
  end
end
