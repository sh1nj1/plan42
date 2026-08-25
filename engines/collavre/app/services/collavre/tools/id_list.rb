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
    #
    # Lenient about shape, strict about content. A token that is not entirely
    # digits raises rather than coercing: to_i turns "12.5" into 12 and
    # "123oops" into 123, and topic_create/topic_branch would then move a
    # different message than the one named and report success. A tool that
    # silently acts on a neighbouring id is worse than one that fails.
    module IdList
      module_function

      DIGITS = /\A\d+\z/

      def parse(value)
        Array(value)
          .flat_map { |entry| entry.to_s.split(",") }
          .filter_map { |token| token.strip.presence }
          .map { |token| cast(token) }
          .uniq
      end

      def cast(token)
        raise ArgumentError, "#{token.inspect} is not a valid id — ids must be whole numbers" unless token.match?(DIGITS)

        token.to_i
      end
    end
  end
end
