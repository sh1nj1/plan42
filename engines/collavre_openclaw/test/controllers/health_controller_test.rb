require "test_helper"

module CollavreOpenclaw
  class HealthControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    test "returns health status" do
      get health_path

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "ok", json["status"]
      assert_equal "collavre_openclaw", json["engine"]
      assert_equal CollavreOpenclaw::VERSION, json["version"]
    end
  end
end
