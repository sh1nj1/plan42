class UserMentionMenuComponent < ViewComponent::Base
  def initialize(menu_id: "mention-menu")
    @menu_id = menu_id
  end
  attr_reader :menu_id
end
