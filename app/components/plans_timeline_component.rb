class PlansTimelineComponent < ViewComponent::Base
  def initialize(plans:)
    @start_date = Date.current - 30
    @end_date = Date.current + 30
    @plans = plans
      .where("target_date >= ? AND created_at <= ?", @start_date, @end_date)
      .order(:created_at)
  end

  attr_reader :plans, :start_date, :end_date

  def plan_data
    @plan_data ||= @plans.map do |plan|
      {
        id: plan.id,
        name: plan.name.presence || I18n.l(plan.target_date),
        created_at: plan.created_at.to_date,
        target_date: plan.target_date,
        progress: plan.progress
      }
    end
  end
end
