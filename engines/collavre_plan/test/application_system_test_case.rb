# frozen_string_literal: true

# Use the main collavre engine's system test infrastructure
require_relative "../../collavre/test/application_system_test_case"

class CollavrePlanSystemTestCase < ApplicationSystemTestCase
  # Helper to access CollavrePlan engine routes
  def collavre_plan
    CollavrePlan::Engine.routes.url_helpers
  end
end
