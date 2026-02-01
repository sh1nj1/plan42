require "test_helper"

module CollavreOpenclaw
  class HealthControllerTest < ActionDispatch::IntegrationTest
    # Define only the needed URL helpers to avoid test_ prefixed helpers being detected as test methods
    def health_path
      "/openclaw/health"
    end

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
