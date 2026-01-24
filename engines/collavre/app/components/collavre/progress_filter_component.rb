module Collavre
class ProgressFilterComponent < ViewComponent::Base
  def initialize(current_state:, states: [])
    @current_state = current_state&.to_sym
    @states = states
  end

  attr_reader :current_state, :states
end
end
