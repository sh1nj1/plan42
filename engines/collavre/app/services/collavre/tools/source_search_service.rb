# frozen_string_literal: true

module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class SourceSearchService
    extend T::Sig
    extend ToolMeta
    include SourceToolSupport

    tool_name "collavre_source_search"
    tool_description "Search Collavre source code for a literal, case-insensitive text. Returns matching " \
                     "file paths, line numbers and lines. Narrow the search with a directory or file path."

    tool_param :query, description: "Text to search for (literal, case-insensitive).", required: true
    tool_param :path, description: "Directory or file relative to the project root to search in. Omit to search everything readable.", required: false

    sig { params(query: String, path: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
    def call(query:, path: nil)
      with_source_access { |browser| browser.search(query, path: path) }
    end
  end
end
end
