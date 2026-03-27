require "test_helper"

module CollavreOpenclaw
  class HealthControllerTest < ActionDispatch::IntegrationTest
    # Define only the needed URL helpers to avoid test_ prefixed helpers being detected as test methods
    def health_path
      "/openclaw/health"
    end

    test "returns health status with websocket info" do
      get health_path

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "ok", json["status"]
      assert_equal "collavre_openclaw", json["engine"]
      assert_equal CollavreOpenclaw::VERSION, json["version"]
      assert_includes %w[auto http], json["transport"]

      ws = json["websocket"]
      assert_not_nil ws
      assert ws.key?("total_connections")
      assert ws.key?("total_users")
      assert ws.key?("connected")
      assert ws.key?("connecting")
      assert ws.key?("reconnecting")
      assert ws.key?("disconnected")

      reactor = json["reactor"]
      assert_not_nil reactor
      assert [ true, false ].include?(reactor["running"])
    end
  end
end
