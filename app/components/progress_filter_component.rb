class ProgressFilterComponent < ViewComponent::Base
  def initialize(progress_state: :all)
    @progress_state = progress_state.to_sym
  end

  attr_reader :progress_state
end
