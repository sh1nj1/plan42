# frozen_string_literal: true

module Collavre
  module Topics
    # The default name for a newly created topic: the localized prefix followed
    # by the next unused number ("Topic 3").
    #
    # Extracted from TopicsController so the topic_create MCP tool produces the
    # same names as the UI. An agent fanning work out across topics names them
    # far more often than a human does, and two generators would have drifted
    # into two numbering series in the same sidebar.
    module NextName
      module_function

      # Archived topics count towards the next number. Topic names are unique
      # per creative whether or not the topic is archived, so the previous
      # active-only scan could propose a name that cannot be saved: archive
      # "Topic 1" on an otherwise unnumbered creative and the next create
      # proposes "Topic 1" again and fails validation. Reachable by hand before,
      # routine once an agent creates topics in a loop.
      def for(creative)
        prefix = I18n.t("collavre.topics.default_name_prefix")
        existing_numbers = creative.topics
          .where("name LIKE ?", "#{Topic.sanitize_sql_like(prefix)}%")
          .pluck(:name)
          .filter_map { |n|
            suffix = n.delete_prefix(prefix)
            suffix.match?(/\A\d+\z/) ? suffix.to_i : nil
          }

        "#{prefix}#{(existing_numbers.max || 0) + 1}"
      end
    end
  end
end
