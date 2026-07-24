ENV["RAILS_ENV"] ||= "test"
require_relative "../../../test/test_helper"
require "collavre_linear"

class ActionDispatch::IntegrationTest
  def linear_engine
    CollavreLinear::Engine.routes.url_helpers
  end
end
