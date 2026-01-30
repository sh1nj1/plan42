module Collavre
  class AutocompletePopupComponent < ViewComponent::Base
    def initialize(menu_id:, extra_classes: nil)
      @menu_id = menu_id
      @extra_classes = extra_classes
    end

    attr_reader :menu_id, :extra_classes

    def css_classes
      ["common-popup", extra_classes].compact.join(" ")
    end

    def list_classes
      ["common-popup-list", extra_classes ? "#{extra_classes.split.first}-results" : nil].compact.join(" ")
    end
  end
end
