# frozen_string_literal: true

module Collavre
  class OnboardingsController < ApplicationController
    before_action :ensure_current_session!, only: %i[advance complete]

    def show
      render json: state
    end

    def advance
      Onboarding::ProgressTracker.record(user: Current.user, event: :ui)
      render json: state
    end

    def complete
      Onboarding::CompletionService.new(user: Current.user).call(defer_pending_agent_cleanup: true)
      render json: { success: true, redirect_url: features_path }
    end

    def reset
      previous_session = Onboarding::Session.for_user(Current.user)
      Onboarding::CompletionService.new(user: Current.user).call(defer_pending_agent_cleanup: true)
      retire_pending_session!(previous_session)
      Current.user.update!(
        creative_workspace_enabled: true,
        onboarding_seeded_at: nil,
        onboarding_completed_at: nil
      )
      Onboarding::Seeder.new(user: Current.user, force: true).call
      redirect_to creatives_path
    end

    private

    # A card can outlive its session when onboarding is reset in another tab.
    # Do not let that stale card advance or delete the replacement session.
    def ensure_current_session!
      session = Onboarding::Session.for_user(Current.user)
      return if session && session.session_id == params[:session_id]

      render json: { error: "onboarding session is no longer current" }, status: :conflict
    end

    # A pending agent turn keeps its old tree until it settles, but that tree
    # cannot remain the active session or reseeding would resume it instead.
    # Keep the session id for the deferred cleanup job and retire only its
    # scenario marker, which is what Session.for_user uses to find the guide.
    def retire_pending_session!(session)
      root = Creative.find_by(id: session&.root&.id)
      return unless root

      root.with_lock do
        onboarding = root.reload.data.fetch("onboarding", {}).deep_dup
        return if onboarding["scenario_key"].blank?

        onboarding.delete("scenario_key")
        root.update!(data: root.data.merge("onboarding" => onboarding))
      end
    end

    def state
      session = Onboarding::Session.for_user(Current.user)
      step = session&.current_step
      return { success: true, current_step: nil } unless session

      {
        success: true,
        current_step: step&.key,
        anchor: step&.anchor,
        anchor_key: session.anchor_key(step),
        navigation_path: session.navigation_path(step, script_name: request.script_name),
        completion: step&.completion,
        complete: session.data["current_step"] == "complete",
        completed_steps: session.data.fetch("steps", {}).select { |_key, value| value["status"] == "completed" }.keys,
        instruction: step ? t("collavre.onboarding.steps.#{step.key}.body") : t("collavre.onboarding.card.complete")
      }
    end
  end
end
