class PopupMenuComponent < ViewComponent::Base
  def initialize(button_content:, button_classes: "", menu_id: nil, align: :left, button_attributes: {})
    @button_content = button_content
    @button_classes = button_classes
    @menu_id = menu_id || "popup-menu-#{SecureRandom.hex(4)}"
    @align = align
    @button_attributes = button_attributes
  end

  attr_reader :button_content, :button_classes, :menu_id, :align, :button_attributes

  def button_options
    defaults = {
      type: "button",
      class: ["popup-menu-toggle", button_classes.presence].compact.join(" "),
      data: {
        action: "click->popup-menu#toggle",
        popup_menu_target: "button"
      }
    }

    return defaults if button_attributes.blank?

    defaults.deep_merge(button_attributes) do |key, this_val, other_val|
      key == :class ? [this_val, other_val].compact.join(" ") : other_val
    end
  end
end
