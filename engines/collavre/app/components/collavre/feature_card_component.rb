# frozen_string_literal: true

module Collavre
  class FeatureCardComponent < ViewComponent::Base
    def initialize(card:, surface:, creative:, onboarding_state: nil)
      @card = card
      @surface = surface.to_sym
      @creative = creative
      @onboarding_state = onboarding_state || {}
    end

    attr_reader :card, :surface, :creative, :onboarding_state

    def comment_empty?
      surface == :comment_empty
    end

    def onboarding?
      surface == :onboarding
    end

    def onboarding_action
      @onboarding_action ||= Onboarding::ActionRegistry.find(onboarding_state["step_key"])
    end

    def status
      onboarding_state["status"].presence || "pending"
    end

    def completed?
      status == "completed"
    end

    def can_interact?
      !onboarding? || creative.user_id == Current.user&.id
    end

    def waiting_for_agent?
      completed? && onboarding_state["response_status"] == "waiting"
    end

    def action_label
      return unless onboarding_action
      return I18n.t("collavre.onboarding.actions.edit_created") if edit_created_action?

      I18n.t(onboarding_action.label_key)
    end

    def action_url
      return unless target_creative

      case onboarding_action&.type
      when :add_or_edit_child
        mounted_creatives_path(
          id: target_creative.id,
          onboarding_action: "edit",
          onboarding_target_id: target_creative.id
        )
      when :focus_progress
        mounted_creatives_path(
          id: target_creative.id,
          onboarding_action: "progress",
          onboarding_target_id: target_creative.id
        )
      when :open_chat
        mounted_creatives_path(id: target_creative.id, open_comments: true, onboarding_action: "chat")
      when :mention_agent
        mounted_creatives_path(id: target_creative.id, open_comments: true, onboarding_action: "mention")
      end
    end

    def add_child_action?
      onboarding_action&.type == :add_or_edit_child && target_creative.nil?
    end

    def guide_url
      return card.guide_url if card.guide_url?
      return unless card.builtin_guide?

      helpers.collavre.feature_path(card.key, locale: I18n.locale, script_name: request.script_name)
    end

    private

    def edit_created_action?
      onboarding_action&.type == :add_or_edit_child && target_creative.present?
    end

    def target_creative
      return @target_creative if defined?(@target_creative)

      candidate = Creative.where(user: creative.user).find_by(id: onboarding_state["target_creative_id"])
      @target_creative = candidate if candidate&.onboarding_practice? &&
                                      candidate.onboarding_metadata.values_at("session_id", "step_key") ==
                                        onboarding_state.values_at("session_id", "step_key")
    end

    def mounted_creatives_path(**params)
      helpers.collavre.creatives_path(**params, script_name: request.script_name)
    end
  end
end
