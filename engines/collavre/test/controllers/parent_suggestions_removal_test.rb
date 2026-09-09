require "test_helper"

class ParentSuggestionsRemovalTest < ActiveSupport::TestCase
  test "parent suggestions endpoint is not routable" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/creatives/1/parent_suggestions.json", method: :get)
    end
  end
end
