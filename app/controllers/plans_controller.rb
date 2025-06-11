class PlansController < ApplicationController
  def index
    respond_to do |format|
      format.html
      format.json do
        start_date = params[:start]&.to_date
        end_date = params[:end]&.to_date
        plans = Plan.where(owner: Current.user).or(Plan.where(owner: nil))
        plans = plans.where(target_date: start_date..end_date) if start_date && end_date
        render json: plans.group_by(&:target_date).transform_values { |ps| ps.map(&:name) }
      end
    end
  end

  def create
    @plan = Plan.new(plan_params)
    @plan.owner = Current.user
    if @plan.save
      redirect_back fallback_location: root_path, notice: "Plan was successfully created."
    else
      flash[:alert] = @plan.errors.full_messages.join(", ")
      redirect_back fallback_location: root_path
    end
  end

  def destroy
    @plan = Plan.find(params[:id])
    @plan.destroy
    redirect_back fallback_location: root_path, notice: t("plans.deleted", default: "Plan deleted.")
  end

  private

  def plan_params
    params.require(:plan).permit(:name, :target_date)
  end
end
