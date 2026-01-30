module Collavre
  class CommandMenuComponent < AutocompletePopupComponent
    def initialize(menu_id: "command-menu")
      super(menu_id: menu_id, extra_classes: nil)
    end
  end
end
