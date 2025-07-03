class PlansController < ApplicationController
  def create
    @plan = Plan.new(plan_params)
    @plan.owner = Current.user
    if @plan.save
      redirect_back fallback_location: root_path, notice: t("plans.created")
    else
      flash[:alert] = @plan.errors.full_messages.join(", ")
      redirect_back fallback_location: root_path
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
end
