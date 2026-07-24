require "test_helper"

module CollavreOpenclaw
  class HealthControllerTest < ActionDispatch::IntegrationTest
    # Define only the needed URL helpers to avoid test_ prefixed helpers being detected as test methods
    def health_path
      "/openclaw/health"
    end

    test "returns basic health without auth" do
      get health_path

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "ok", json["status"]
      assert_equal "collavre_openclaw", json["engine"]
      assert_equal CollavreOpenclaw::VERSION, json["version"]

      # WebSocket details should NOT be exposed without auth
      assert_nil json["websocket"], "WebSocket status should not be public"
      assert_nil json["reactor"], "Reactor status should not be public"
      assert_nil json["transport"], "Transport config should not be public"
    end
  end
end
