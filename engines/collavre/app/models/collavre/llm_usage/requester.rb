# frozen_string_literal: true

module Collavre
  class LlmUsage
    class Requester < ApplicationRecord
      self.table_name = "llm_usage_requesters"
    end
  end
end
