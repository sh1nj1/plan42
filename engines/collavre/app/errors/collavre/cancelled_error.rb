# frozen_string_literal: true

module Collavre
  class CancelledError < StandardError
    def initialize(message = "Task was cancelled")
      super(message)
    end
  end
end
