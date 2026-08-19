# frozen_string_literal: true

module Collavre
  module Tools
    # Parses the "list of ids" parameters the topic tools take.
    #
    # MCP schemas describe a list, but what actually arrives depends on the
    # calling model: "12,45", ["12", 45], 12 and "12" are all things an agent
    # writes when it means the same thing. Rejecting four fifths of those is a
    # tool that fails for a reason the caller cannot see in its own request, so
    # every shape is accepted here instead of at four separate call sites.
    module IdList
      module_function

      def parse(value)
        Array(value)
          .flat_map { |entry| entry.to_s.split(",") }
          .filter_map { |token| token.strip.presence }
          .map(&:to_i)
          .uniq
      end
    end
  end
end
