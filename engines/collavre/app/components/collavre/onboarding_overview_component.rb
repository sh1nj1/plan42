# frozen_string_literal: true

module Collavre
  class OnboardingOverviewComponent < ViewComponent::Base
    def initialize(creative:)
      @creative = creative
    end

    attr_reader :creative

    def completed_steps
      onboarding_cards.count { |item| item.onboarding_metadata["status"] == "completed" }
    end

    def total_steps
      onboarding_cards.size
    end

    def completed?
      total_steps.positive? && completed_steps == total_steps
    end

    def owner?
      creative.user_id == Current.user&.id
    end

    def completion_label
      I18n.t(completed? ? "collavre.onboarding.overview.finish" : "collavre.onboarding.overview.skip")
    end

    def completion_confirmation
      I18n.t(completed? ? "collavre.onboarding.overview.confirm_finish" : "collavre.onboarding.overview.confirm_skip")
    end

    def onboarding_path
      helpers.collavre.onboarding_path(script_name: request.script_name)
    end

    def features_path
      helpers.collavre.features_path(script_name: request.script_name)
    end

    private

    def session_items
      @session_items ||= Creative.where(user: creative.user).select do |item|
        item.onboarding_metadata&.dig("session_id") == creative.onboarding_metadata["session_id"]
      end
    end

    def onboarding_cards
      @onboarding_cards ||= session_items.select(&:onboarding_card?)
    end
  end
end
