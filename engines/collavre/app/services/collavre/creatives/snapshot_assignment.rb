# frozen_string_literal: true

module Collavre
  module Creatives
    class SnapshotAssignment
      def self.call(creative, snapshot)
        if snapshot["content_type"] == "markdown"
          creative.content_type_input = "markdown"
          creative.markdown_source = snapshot["markdown_source"].to_s
          creative.markdown_editor = snapshot["editor"]
        else
          creative.content_type_input = "html"
          creative.description = snapshot["description"]
        end
        creative.assign_attributes(
          parent_id: snapshot["parent_id"],
          sequence: snapshot["sequence"],
          progress: snapshot["progress"],
          archived_at: snapshot["archived_at"]
        )
      end
    end
  end
end
