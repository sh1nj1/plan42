# frozen_string_literal: true

module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class SourceReadService
    extend T::Sig
    extend ToolMeta
    include SourceToolSupport

    tool_name "collavre_source_read"
    tool_description "Read a Collavre source file with line numbers. Returns up to " \
                     "#{SourceBrowser::MAX_READ_LINES} lines per call; use start_line/end_line to page."

    tool_param :path, description: "File path relative to the project root, e.g. 'engines/collavre/app/models/collavre/topic.rb'.", required: true
    tool_param :start_line, description: "First line to return (1-indexed). Defaults to 1.", required: false
    tool_param :end_line, description: "Last line to return (inclusive).", required: false

    sig { params(path: String, start_line: T.nilable(Integer), end_line: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
    def call(path:, start_line: nil, end_line: nil)
      with_source_access { |browser| browser.read(path, start_line: start_line || 1, end_line: end_line) }
    end
  end
end
end
