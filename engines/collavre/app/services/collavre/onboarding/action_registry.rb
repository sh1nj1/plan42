# frozen_string_literal: true

module Collavre
  module Onboarding
    class ActionRegistry
      Action = Data.define(:type, :label_key)

      ACTIONS = {
        "create_edit" => Action.new(
          type: :add_or_edit_child,
          label_key: "collavre.onboarding.actions.create_edit"
        ),
        "progress_rollup" => Action.new(
          type: :focus_progress,
          label_key: "collavre.onboarding.actions.progress_rollup"
        ),
        "creative_chat" => Action.new(
          type: :open_chat,
          label_key: "collavre.onboarding.actions.creative_chat"
        ),
        "mention_agent" => Action.new(
          type: :mention_agent,
          label_key: "collavre.onboarding.actions.mention_agent"
        )
      }.freeze

      def self.find(step_key)
        ACTIONS[step_key.to_s]
      end
    end
  end
end
