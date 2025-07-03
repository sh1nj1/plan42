class PlansController < ApplicationController
  def index
    start_date = Date.current - 30
    end_date = Date.current + 30
    @plans = Plan.where(owner: Current.user).or(Plan.where(owner: nil))
                 .where("target_date >= ? AND created_at <= ?", start_date, end_date)
                 .order(:created_at)
    respond_to do |format|
      format.html do
        render html: render_to_string(PlansTimelineComponent.new(plans: @plans)).html_safe
      end
      format.json do
        render json: @plans.map { |p| plan_json(p) }
      end
    end
  end
  def create
    @plan = Plan.new(plan_params)
    @plan.owner = Current.user
    if @plan.save
      respond_to do |format|
        format.html do
          redirect_back fallback_location: root_path, notice: t("plans.created")
        end
        format.json do
          render json: plan_json(@plan), status: :created
        end
      end
    else
      respond_to do |format|
        format.html do
          flash[:alert] = @plan.errors.full_messages.join(", ")
          redirect_back fallback_location: root_path
        end
        format.json do
          render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
        end
      end
    end
  end

  def destroy
    @plan = Plan.find(params[:id])
    @plan.destroy
    respond_to do |format|
      format.html do
        redirect_back fallback_location: root_path,
                      notice: t("plans.deleted", default: "Plan deleted.")
      end
      format.json { head :no_content }
    end
  end

  private

  def plan_params
    params.require(:plan).permit(:name, :target_date)
  end

  def plan_json(plan)
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

  def plan_creatives_path(plan)
    if params[:id].present?
      creative_path(params[:id], tags: [ plan.id ])
    else
      creatives_path(tags: [ plan.id ])
    end
  end
end
