# frozen_string_literal: true

module Collavre
  module Onboarding
    # Stable public names for DOM locations used by scenario definitions.
    # Views own selectors; scenarios only ever refer to these names.
    class AnchorRegistry
      ANCHORS = %w[
        tree.panel tree.toggle tree.node tree.add tree.progress creative.editor
        chat.toggle chat.composer
      ].freeze

      def self.registered?(anchor)
        ANCHORS.include?(anchor.to_s)
      end
    end
  end
end
