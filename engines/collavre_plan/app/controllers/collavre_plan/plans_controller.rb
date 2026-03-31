module CollavrePlan
  class PlansController < ApplicationController
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
      respond_to do |format|
        format.html do
          render html: render_to_string(Collavre::PlansTimelineComponent.new(plans: @plans, calendar_events: @calendar_events), layout: false)
        end
        format.json do
          plan_jsons = @plans.map { |p| plan_json(p) }
          event_jsons = @calendar_events.map { |e| calendar_json(e) }
          render json: plan_jsons + event_jsons
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
      @plan = Collavre::Plan.find(params[:id])
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
      @plan = Collavre::Plan.find(params[:id])
      return render_forbidden unless plan_editable_by_current_user?

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

    def render_forbidden
      respond_to do |format|
        format.html do
          redirect_back fallback_location: main_app.root_path,
                        alert: t("collavre.plans.update_forbidden", default: "You do not have permission to update this plan.")
        end
        format.json do
          render json: { error: "forbidden" }, status: :forbidden
        end
      end
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
