module CollavrePlan
  class TimelineItems
    def initialize(creative_id: nil)
      @creative_id = creative_id
      @routes = Collavre::Engine.routes.url_helpers
    end

    def all(plans:, calendar_events:, registrations:, modifications:)
      plans.map { |record| plan(record) } +
        calendar_events.map { |event| calendar_event(event) } +
        registrations.map { |creative| registration(creative) } +
        modifications.map { |creative| modification(creative) }
    end

    def plan(plan)
      {
        id: plan.id,
        name: (plan.creative&.effective_description(nil, false) || plan.name.presence || I18n.l(plan.target_date)),
        created_at: plan.created_at.to_date,
        start_date: plan.start_date,
        target_date: plan.target_date,
        progress: plan.progress,
        path: plan_creatives_path(plan),
        deletable: plan.owner_id == Collavre::Current.user&.id
      }
    end

    def calendar_event(event)
      {
        id: "calendar_event_#{event.id}",
        name: event.summary.presence || I18n.l(event.start_time.to_date),
        created_at: event.start_time.to_date,
        target_date: event.end_time.to_date,
        progress: event.creative&.progress || 0,
        path: event.creative ? @routes.creative_path(event.creative) : event.html_link,
        deletable: event.user_id == Collavre::Current.user&.id
      }
    end

    def registration(creative)
      marker(creative, "registration", creative.created_at.to_date,
             I18n.t("collavre.plans.registration_fallback", id: creative.id))
    end

    def modification(creative)
      marker(creative, "modification", creative.updated_at.to_date,
             I18n.t("collavre.plans.modification_fallback", id: creative.id))
    end

    private

    def marker(creative, type, date, fallback_name)
      {
        id: "#{type}_#{creative.id}",
        type: type,
        name: creative.effective_description(nil, false).presence || fallback_name,
        created_at: date,
        target_date: date,
        progress: creative.progress,
        path: @routes.creative_path(creative),
        deletable: false
      }
    end

    def plan_creatives_path(plan)
      if @creative_id.present?
        @routes.creative_path(@creative_id, tags: [ plan.id ])
      else
        @routes.creatives_path(tags: [ plan.id ])
      end
    end
  end
end
