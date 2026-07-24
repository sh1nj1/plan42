# frozen_string_literal: true

module Collavre
  module Tools
    # Raised by tool services when the current user lacks the required
    # creative-level permission to perform a mutating action.
    class PermissionDeniedError < StandardError; end
  end
end
