require "test_helper"

module CollavreOpenclaw
  class OpenclawAccountTest < ActiveSupport::TestCase
    test "validates presence of gateway_url" do
      account = OpenclawAccount.new(gateway_url: nil)
      assert_not account.valid?
      assert_includes account.errors[:gateway_url], "can't be blank"
    end

    test "api_endpoint builds correct URL" do
      account = OpenclawAccount.new(gateway_url: "https://my-gateway.com")
      assert_equal "https://my-gateway.com/v1/chat/completions", account.api_endpoint
    end

    test "api_endpoint handles URL with path" do
      account = OpenclawAccount.new(gateway_url: "https://my-gateway.com/some/path")
      assert_equal "https://my-gateway.com/v1/chat/completions", account.api_endpoint
    end
  end
end
