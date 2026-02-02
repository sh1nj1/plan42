# frozen_string_literal: true

# Use the main collavre engine's system test infrastructure
require_relative "../../collavre/test/application_system_test_case"

class CollavreOpenclawSystemTestCase < ApplicationSystemTestCase
  # Helper to access CollavreOpenclaw engine routes
  def collavre_openclaw
    CollavreOpenclaw::Engine.routes.url_helpers
  end
end
