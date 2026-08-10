# frozen_string_literal: true

module Collavre
  module Onboarding
    # Definitions intentionally describe a target and completion signal only.
    # A future read-only playback mode can reuse these definitions safely.
    class ScenarioRegistry
      Step = Data.define(:key, :anchor, :completion, :panel, :target)
      Scenario = Data.define(:key, :steps)

      FIRST_STEPS = Scenario.new(
        :first_steps,
        [
          Step.new(:tree_node, "tree.node", :ui, :tree, :root),
          Step.new(:progress, "tree.progress", :progress_changed, :tree, :first_practice),
          Step.new(:editor, "creative.editor", :description_changed, :editor, :second_practice),
          Step.new(:comment, "chat.composer", :comment_created, :chat, :second_practice),
          Step.new(:mention, "chat.composer", :agent_mentioned, :chat, :second_practice)
        ].freeze
      )

      SCENARIOS = { FIRST_STEPS.key.to_s => FIRST_STEPS }.freeze

      def self.fetch(key)
        SCENARIOS.fetch(key.to_s)
      end

      def self.all
        SCENARIOS.values
      end
    end
  end
end
