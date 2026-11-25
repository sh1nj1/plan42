require "test_helper"

class ProxyErrorResponseTest < ActiveSupport::TestCase
  test "both proxy controllers preserve error payload and accept only HTTP error statuses" do
    [ Collavre::AgentConnectionsController, Collavre::InlineAgentLoginsController ].each do |controller_class|
      [ nil, 200, 399, 400, 422, 599, 600 ].each do |status|
        error = Collavre::CliProxy::Client::Error.new("Proxy failed", status: status, code: "proxy_failed")
        controller = controller_class.new
        rendered = nil
        controller.stub(:render, ->(**options) { rendered = options }) do
          controller.send(:render_proxy_error, error)
        end
        assert_equal({ error: { message: "Proxy failed", code: "proxy_failed" } }, rendered[:json])
        assert_equal(status.to_i.between?(400, 599) ? status : :bad_gateway, rendered[:status])
      end
    end
  end

  test "connection exception handler does not handle non-proxy actions" do
    controller = Collavre::AgentConnectionsController.new
    error = Collavre::CliProxy::Client::Error.new("Unexpected error")
    [ "show", "rotate_tokens" ].each do |action|
      controller.stub(:action_name, action) do
        assert_same error, assert_raises(Collavre::CliProxy::Client::Error) {
          controller.send(:render_connection_proxy_error, error)
        }
      end
    end
  end
end
