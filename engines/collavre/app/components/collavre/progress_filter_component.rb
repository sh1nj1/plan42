module Collavre
class ProgressFilterComponent < ViewComponent::Base
  # Progress/comment params are only consumed by Creatives::IndexQuery, so the
  # buttons carry the creative index path and whether we are already on it.
  # See app/javascript/lib/utils/filter_navigation.js.
  PROGRESS_VALUES = %w[all complete incomplete].freeze

  def initialize(current_state:, states: [])
    @current_state = current_state&.to_sym
    @states = states
  end

  attr_reader :current_state, :states

  def index_path
    helpers.collavre.creatives_path
  end

  def on_index?
    helpers.creative_index_page?
  end

  # Mirrors the keys syncFilterButtons() derives from the URL, so a frame-only
  # navigation can re-apply the `active` class without a server round trip.
  def filter_state_key(value)
    value = value.to_s
    PROGRESS_VALUES.include?(value) ? "progress:#{value}" : value
  end
end
end
