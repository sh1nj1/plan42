module Collavre
class PlansTimelineComponent < ViewComponent::Base
  # Accepts pre-filtered plans, calendar_events, registrations and modifications from the controller
  def initialize(plans:, calendar_events: Collavre::CalendarEvent.none, registrations: [], show_registrations: false, modifications: [], show_modifications: false)
    @start_date = Date.current - 30
    @end_date = Date.current + 30
    @plans = plans
    @calendar_events = calendar_events
    @registrations = registrations
    @show_registrations = show_registrations
    @modifications = modifications
    @show_modifications = show_modifications
  end

  attr_reader :plans, :calendar_events, :registrations, :start_date, :end_date, :show_registrations, :modifications, :show_modifications

  # Called after component enters render context - safe to use helpers here
  def plan_data
    @plan_data ||= CollavrePlan::TimelineItems.new(creative_id: helpers.params[:id], routes: helpers.collavre).all(
      plans: @plans, calendar_events: @calendar_events, registrations: @registrations, modifications: @modifications
    )
  end
end
end
