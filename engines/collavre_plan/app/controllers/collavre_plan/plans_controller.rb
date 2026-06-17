module CollavrePlan
  class PlansController < ApplicationController
    # Cap how many registration markers we draw so a busy window never floods
    # the timeline (or the JSON payload). Most recent within the window win.
    REGISTRATION_LIMIT = 300

    def index
      center = if params[:date].present?
                  Date.parse(params[:date]) rescue Date.current
      else
                  Date.current
      end
      start_date = center - 30
      end_date = center + 30
      @plans = Collavre::Plan.joins(:creative)
                   .where("target_date >= ? AND DATE(creatives.created_at) <= ?", start_date, end_date)
                   .order(Arel.sql("DATE(creatives.created_at) ASC"))
                   .select { |plan| plan.readable_by?(Current.user) }
      calendar_scope = Collavre::CalendarEvent.includes(:creative)
                                    .where("DATE(start_time) <= ? AND DATE(end_time) >= ?", end_date, start_date)
                                    .order(:start_time)
      events_in_scope = calendar_scope.to_a
      own_events = events_in_scope.select { |event| event.user_id == Current.user.id }
      shared_events = events_in_scope.reject { |event| event.user_id == Current.user.id }
                                     .select { |event| event.creative&.has_permission?(Current.user, :write) }
      @calendar_events = (own_events + shared_events).uniq.sort_by(&:start_time)

      # "Registered" chip is default-off, so registrations are only gathered when
      # the client explicitly asks for them (lazy, zero cost on normal loads).
      @show_registrations = ActiveModel::Type::Boolean.new.cast(params[:registrations]) == true
      @registrations = @show_registrations ? registration_creatives(start_date, end_date) : []

      respond_to do |format|
        format.html do
          render html: render_to_string(Collavre::PlansTimelineComponent.new(plans: @plans, calendar_events: @calendar_events, registrations: @registrations, show_registrations: @show_registrations), layout: false)
        end
        format.json do
          plan_jsons = @plans.map { |p| plan_json(p) }
          event_jsons = @calendar_events.map { |e| calendar_json(e) }
          registration_jsons = @registrations.map { |c| registration_json(c) }
          render json: plan_jsons + event_jsons + registration_jsons
        end
      end
    end

    def create
      @plan = Collavre::Plan.new(plan_params)
      @plan.owner = Current.user
      if @plan.save
        respond_to do |format|
          format.html do
            redirect_back fallback_location: main_app.root_path, notice: t("collavre.plans.created")
          end
          format.json do
            render json: plan_json(@plan), status: :created
          end
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = @plan.errors.full_messages.join(", ")
            redirect_back fallback_location: main_app.root_path
          end
          format.json do
            render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end

    def destroy
      @plan = Collavre::Plan.find_by(id: params[:id])
      raise ActiveRecord::RecordNotFound unless @plan && plan_editable_by_current_user?

      @plan.destroy
      respond_to do |format|
        format.html do
          redirect_back fallback_location: main_app.root_path,
                        notice: t("collavre.plans.deleted", default: "Plan deleted.")
        end
        format.json { head :no_content }
      end
    end

    def update
      @plan = Collavre::Plan.find_by(id: params[:id])
      raise ActiveRecord::RecordNotFound unless @plan && plan_editable_by_current_user?

      if @plan.update(plan_update_params)
        respond_to do |format|
          format.html do
            redirect_back fallback_location: main_app.root_path,
                          notice: t("collavre.plans.updated", default: "Plan updated.")
          end
          format.json do
            render json: plan_json(@plan, creative_id: params[:creative_id] || @plan.creative_id), status: :ok
          end
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = @plan.errors.full_messages.join(", ")
            redirect_back fallback_location: main_app.root_path
          end
          format.json do
            render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end

    private

    def plan_params
      params.require(:plan).permit(:target_date, :start_date, :creative_id)
    end

    def plan_update_params
      params.require(:plan).permit(:target_date, :start_date)
    end

    def plan_editable_by_current_user?
      return true if @plan.owner_id == Current.user&.id
      return true if @plan.creative&.has_permission?(Current.user, :write)

      tagged_creative = Collavre::Creative.find_by(id: params[:creative_id])
      return false unless tagged_creative
      return false unless @plan.tags.exists?(creative_id: tagged_creative.id)

      tagged_creative.has_permission?(Current.user, :write)
    end

    # Registered creatives owned by the current user, drawn at their created_at.
    # Owner-scoped (cheap, indexed) and capped — readable-but-shared creatives are
    # intentionally a follow-up to avoid a per-creative permission fan-out here.
    def registration_creatives(start_date, end_date)
      # Range-compare in the user's zone (set_time_zone wraps the request in
      # Time.use_zone) so day-edge creatives match the local created_at.to_date
      # we render the marker at; also stays sargable (no DATE() cast on the column).
      Collavre::Creative.active
                        .where(user_id: Current.user.id)
                        .where(created_at: start_date.beginning_of_day..end_date.end_of_day)
                        .order(created_at: :desc)
                        .limit(REGISTRATION_LIMIT)
                        .to_a
    end

    def registration_json(creative)
      {
        id: "registration_#{creative.id}",
        type: "registration",
        name: (creative.effective_description(nil, false).presence || I18n.t("collavre.plans.registration_fallback", id: creative.id)),
        created_at: creative.created_at.to_date,
        target_date: creative.created_at.to_date,
        progress: creative.progress,
        path: Collavre::Engine.routes.url_helpers.creative_path(creative),
        deletable: false
      }
    end

    def plan_json(plan, creative_id: nil)
      {
        id: plan.id,
        name: (plan.creative&.effective_description(nil, false) || plan.name.presence || I18n.l(plan.target_date)),
        created_at: plan.created_at.to_date,
        start_date: plan.start_date,
        target_date: plan.target_date,
        progress: plan.progress,
        path: plan_creatives_path(plan, creative_id: creative_id),
        deletable: plan.owner_id == Current.user&.id
      }
    end

    def calendar_json(event)
      {
        id: "calendar_event_#{event.id}",
        name: event.summary.presence || I18n.l(event.start_time.to_date),
        created_at: event.start_time.to_date,
        target_date: event.end_time.to_date,
        progress: event.creative&.progress || 0,
        path: event.creative ? Collavre::Engine.routes.url_helpers.creative_path(event.creative) : event.html_link,
        deletable: event.user_id == Current.user&.id
      }
    end

    def plan_creatives_path(plan, creative_id: nil)
      collavre_routes = Collavre::Engine.routes.url_helpers
      if creative_id.present?
        collavre_routes.creative_path(creative_id, tags: [ plan.id ])
      elsif params[:id].present?
        collavre_routes.creative_path(params[:id], tags: [ plan.id ])
      else
        collavre_routes.creatives_path(tags: [ plan.id ])
      end
    end
  end
end
