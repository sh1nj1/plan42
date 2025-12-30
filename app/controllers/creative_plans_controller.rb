class CreativePlansController < ApplicationController
  before_action :require_authentication

  def create
    result = tagger.apply
    respond_to do |format|
      format.html do
        flash[result.success? ? :notice : :alert] = translate_message(
          result,
          success_key: "creatives.index.plan_tags_applied",
          success_default: "Plan tags applied to selected creatives.",
          failure_key: "creatives.index.plan_tag_failed",
          failure_default: "Please select a plan and at least one creative."
        )
        redirect_back fallback_location: creatives_path(select_mode: 1)
      end
      format.json do
        if result.success?
          render json: { message: translate_message(result, success_key: "creatives.index.plan_tags_applied", success_default: "Plan tags applied.", failure_key: "", failure_default: "") }, status: :ok
        else
          render json: { error: translate_message(result, success_key: "", success_default: "", failure_key: "creatives.index.plan_tag_failed", failure_default: "Failed to apply plan.") }, status: :unprocessable_entity
        end
      end
    end
  end

  def destroy
    result = tagger.remove
    respond_to do |format|
      format.html do
        flash[result.success? ? :notice : :alert] = translate_message(
          result,
          success_key: "creatives.index.plan_tags_removed",
          success_default: "Plan tag removed from selected creatives.",
          failure_key: "creatives.index.plan_tag_remove_failed",
          failure_default: "Please select a plan and at least one creative."
        )
        redirect_back fallback_location: creatives_path(select_mode: 1)
      end
      format.json do
        if result.success?
          render json: { message: translate_message(result, success_key: "creatives.index.plan_tags_removed", success_default: "Plan tag removed.", failure_key: "", failure_default: "") }, status: :ok
        else
          render json: { error: translate_message(result, success_key: "", success_default: "", failure_key: "creatives.index.plan_tag_remove_failed", failure_default: "Failed to remove plan.") }, status: :unprocessable_entity
        end
      end
    end
  end

  private

  def tagger
    Creatives::PlanTagger.new(plan_id: params[:plan_id], creative_ids: parsed_creative_ids)
  end

  def parsed_creative_ids
    params[:creative_ids].to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def translate_message(result, success_key:, success_default:, failure_key:, failure_default:)
    if result.success?
      I18n.t(success_key, default: success_default)
    else
      I18n.t(failure_key, default: failure_default)
    end
  end
end
