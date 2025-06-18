class PopupMenuComponent < ViewComponent::Base
  def initialize(button_content:, button_classes: "", menu_id: nil, align: :left, button_id: nil)
    @button_content = button_content
    @button_classes = button_classes
    @menu_id = menu_id || "popup-menu-#{SecureRandom.hex(4)}"
    @align = align
    @button_id = button_id
  end

  attr_reader :button_content, :button_classes, :menu_id, :align, :button_id
end
