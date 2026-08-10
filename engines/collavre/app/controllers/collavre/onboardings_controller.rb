# frozen_string_literal: true

module Collavre
  class OnboardingsController < ApplicationController
    def show
      render json: state
    end

    def advance
      Onboarding::ProgressTracker.record(user: Current.user, event: :ui)
      render json: state
    end

    def complete
      Onboarding::CompletionService.new(user: Current.user).call
      render json: { success: true, redirect_url: features_path }
    end

    def reset
      Onboarding::CompletionService.new(user: Current.user).call
      Current.user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
      Onboarding::Seeder.new(user: Current.user, force: true).call
      redirect_to creatives_path
    end

    private

    def state
      session = Onboarding::Session.for_user(Current.user)
      step = session&.current_step
      return { success: true, current_step: nil } unless session

      {
        success: true,
        current_step: step&.key,
        anchor: step&.anchor,
        completion: step&.completion,
        complete: session.data["current_step"] == "complete",
        completed_steps: session.data.fetch("steps", {}).select { |_key, value| value["status"] == "completed" }.keys,
        instruction: step ? t("collavre.onboarding.steps.#{step.key}.body") : t("collavre.onboarding.card.complete")
      }
    end
  end
end
