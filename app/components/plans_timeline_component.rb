class PlansTimelineComponent < ViewComponent::Base
  def initialize(plans:)
    @plans = plans.order(:target_date)
  end

  attr_reader :plans

  def grouped_plans
    @grouped_plans ||= @plans.group_by(&:target_date)
  end
end
