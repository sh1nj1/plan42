module Collavre
  class CommandMenuComponent < ViewComponent::Base
    def initialize(menu_id: "command-menu")
      @menu_id = menu_id
    end

    attr_reader :menu_id
  end
end
