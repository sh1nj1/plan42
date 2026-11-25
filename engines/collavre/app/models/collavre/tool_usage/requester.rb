# frozen_string_literal: true

module Collavre
  class ToolUsage
    class Requester < ApplicationRecord
      self.table_name = "tool_usage_requesters"
    end
  end
end
