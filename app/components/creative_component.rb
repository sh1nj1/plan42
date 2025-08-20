class CreativeComponent < ViewComponent::Base

  include ApplicationHelper

  def initialize(creative:, filtered_children:, level:, select_mode:, expanded:)
    @creative = creative
    @filtered_children = filtered_children
    @level = level
    @select_mode = select_mode
    @expanded = expanded
  end

  attr_reader :creative, :filtered_children, :level, :select_mode, :expanded

  def drag_attrs
    if select_mode
      { id: "creative-#{creative.id}" }
    else
      {
        draggable: true,
        id: "creative-#{creative.id}",
        ondragstart: "handleDragStart(event)",
        ondragover: "handleDragOver(event)",
        ondrop: "handleDrop(event)"
      }
    end
  end
end
