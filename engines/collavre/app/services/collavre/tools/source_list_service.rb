# frozen_string_literal: true

module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class SourceListService
    extend T::Sig
    extend ToolMeta
    include SourceToolSupport

    tool_name "collavre_source_list"
    tool_description "List Collavre source directories and files. Without a path, returns the readable roots " \
                     "(app code, engines, locales, routes). Pass a directory path relative to the " \
                     "project root to list its entries."

    tool_param :path, description: "Directory relative to the project root, e.g. 'engines/collavre/app/models'. Omit for the roots.", required: false

    sig { params(path: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
    def call(path: nil)
      with_source_access { |browser| browser.list(path) }
    end
  end
end
end
