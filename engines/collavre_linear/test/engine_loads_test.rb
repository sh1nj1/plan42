require_relative "test_helper"

class EngineLoadsTest < ActiveSupport::TestCase
  test "CollavreLinear::Engine is defined" do
    assert defined?(CollavreLinear::Engine), "CollavreLinear::Engine should be defined"
  end

  test "CollavreLinear::VERSION is 0.1.0" do
    assert_equal "0.1.0", CollavreLinear::VERSION
  end

  test "IntegrationRegistry has :linear entry" do
    entry = Collavre::IntegrationRegistry.find(:linear)
    assert entry, "IntegrationRegistry should have a :linear entry"
    assert_equal "Linear", entry.label
    assert_equal "linear", entry.icon
  end

  test "IntegrationRegistry :linear entry has creative_menu_partial" do
    entry = Collavre::IntegrationRegistry.find(:linear)
    assert_equal "collavre_linear/integrations/modal", entry.creative_menu_partial
  end
end
