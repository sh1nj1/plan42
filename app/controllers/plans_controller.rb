class PlansController < ApplicationController
  def create
    @plan = Plan.new(plan_params)
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
