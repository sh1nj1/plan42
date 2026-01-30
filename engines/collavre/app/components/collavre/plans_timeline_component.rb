module Collavre
class PlansTimelineComponent < ViewComponent::Base
  # Accepts pre-filtered plans and calendar_events from the controller
  def initialize(plans:, calendar_events: CalendarEvent.none)
    @plans = plans
    @calendar_events = calendar_events
  end

  attr_reader :plans, :calendar_events

  # Called after component enters render context - safe to use helpers here
  def plan_data
    @plan_data ||= @plans.map { |plan| plan_item(plan) } + @calendar_events.map { |event| calendar_item(event) }
  end

  private

  def plan_item(plan)
    {
      id: plan.id,
      name: (plan.creative&.effective_description(nil, false) || plan.name.presence || I18n.l(plan.target_date)),
      created_at: plan.created_at.to_date,
      start_date: plan.start_date,
      target_date: plan.target_date,
      progress: plan.progress,
      path: plan_creatives_path(plan),
      deletable: plan.owner_id == Current.user&.id
    }
  end

  def calendar_item(event)
    {
      id: "calendar_event_#{event.id}",
      name: event.summary.presence || I18n.l(event.start_time.to_date),
      created_at: event.start_time.to_date,
      target_date: event.end_time.to_date,
      progress: event.creative&.progress || 0,
      path: event.creative ? helpers.collavre.creative_path(event.creative) : event.html_link,
      deletable: event.user_id == Current.user&.id
    }
  end

  def plan_creatives_path(plan)
    if helpers.params[:id].present?
      helpers.collavre.creative_path(helpers.params[:id], tags: [ plan.id ])
    else
      helpers.collavre.creatives_path(tags: [ plan.id ])
    end
  end
end
end
