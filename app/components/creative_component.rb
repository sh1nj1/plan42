class CreativeComponent < ViewComponent::Base
  include CreativesHelper

  def initialize(creative:, level:, expanded_state_map:, select_mode: false)
    @creative = creative
    @level = level
    @expanded_state_map = expanded_state_map
    @select_mode = select_mode
  end

  private

  attr_reader :creative, :level, :expanded_state_map, :select_mode

  def children
    filter_creatives(creative.children_with_permission(Current.user))
  end

  def expanded?
    expanded_from_expanded_state(creative.id, expanded_state_map)
  end

  def load_url
    Rails.application.routes.url_helpers.children_creative_path(creative, level: level + 1)
  end
end
