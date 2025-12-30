class PlansTimelineComponent < ViewComponent::Base
  def initialize(plans:, calendar_events: CalendarEvent.none)
    @start_date = Date.current - 30
    @end_date = Date.current + 30
    @plans = plans
      .where("target_date >= ? AND created_at <= ?", @start_date, @end_date)
      .select { |plan| plan.readable_by?(Current.user) }
      .sort_by(&:created_at)
    @calendar_events = calendar_events
      .includes(:creative)
      .where("DATE(start_time) <= ? AND DATE(end_time) >= ?", @end_date, @start_date)
      .order(:start_time)
  end

  attr_reader :plans, :start_date, :end_date, :calendar_events

  def plan_data
    @plan_data ||= begin
      plan_items = @plans.map do |plan|
        {
          id: plan.id,
          name: plan.name.presence || I18n.l(plan.target_date),
          created_at: plan.created_at.to_date,
          target_date: plan.target_date,
          progress: plan.progress,
          path: plan_creatives_path(plan),
          deletable: plan.owner_id == Current.user&.id
        }
      end
      event_items = @calendar_events.map do |event|
        {
          id: "calendar_event_#{event.id}",
          name: event.summary.presence || I18n.l(event.start_time.to_date),
          created_at: event.start_time.to_date,
          target_date: event.end_time.to_date,
          progress: event.creative&.progress || 0,
          path: event.creative ? helpers.creative_path(event.creative) : event.html_link,
          deletable: event.user_id == Current.user&.id
        }
      end
      plan_items + event_items
    end
  end

  private

  def plan_creatives_path(plan)
    if helpers.params[:id].present?
      helpers.creative_path(helpers.params[:id], tags: [ plan.id ])
    else
      helpers.creatives_path(tags: [ plan.id ])
    end
  end
end
