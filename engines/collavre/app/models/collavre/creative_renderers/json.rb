# frozen_string_literal: true

module Collavre
  module CreativeRenderers
    class Json
      # For kind: "json", description is already provided as HTML from the Lexical editor.
      # The data field stores the Lexical raw JSON as source of truth.
      # We don't render from data → description because the HTML comes directly from the editor.
      # This renderer is a no-op: it returns nil to signal "keep the existing description".
      def self.render(data)
        nil
      end
    end
  end
end
