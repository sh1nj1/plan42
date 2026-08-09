# frozen_string_literal: true

module Collavre
  class OnboardingsController < ApplicationController
    def destroy
      root = Creative.onboarding_guides.where(user: Current.user).find do |creative|
        creative.onboarding_metadata&.dig("session_id").present?
      end
      Onboarding::CompletionService.call(
        user: Current.user,
        session_id: root&.onboarding_metadata&.dig("session_id")
      ) if root

      redirect_to creatives_path, notice: t("collavre.onboarding.completion.notice")
    end
  end
end
