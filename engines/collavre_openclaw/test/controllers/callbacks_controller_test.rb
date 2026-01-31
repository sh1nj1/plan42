require "test_helper"

module CollavreOpenclaw
  class CallbacksControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    setup do
      # Create a test user and account
      @user = User.create!(
        email: "test-openclaw@example.com",
        password: "password123",
        name: "Test Bot"
      )
      @account = OpenclawAccount.create!(
        user: @user,
        gateway_url: "https://test-gateway.com",
        api_token: "test-secret-token",
        channel_id: "test-channel"
      )
    end

    teardown do
      @account&.destroy
      @user&.destroy
    end

    test "returns not_found for non-existent account" do
      post callback_path(account_id: 999999),
           params: { message: "test" }.to_json,
           headers: { "Content-Type" => "application/json" }

      assert_response :not_found
      json = JSON.parse(response.body)
      assert_equal "Account not found", json["error"]
    end

    test "returns unauthorized for missing signature when token is set" do
      post callback_path(account_id: @account.id),
           params: { message: "test" }.to_json,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      json = JSON.parse(response.body)
      assert_equal "Invalid signature", json["error"]
    end

    test "returns unauthorized for invalid signature" do
      body = { message: "test" }.to_json

      post callback_path(account_id: @account.id),
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-OpenClaw-Signature" => "invalid-signature"
           }

      assert_response :unauthorized
      json = JSON.parse(response.body)
      assert_equal "Invalid signature", json["error"]
    end

    test "accepts valid signature" do
      body = { message: "test", content: "Hello from OpenClaw" }.to_json
      signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret-token", body)

      # Use perform_enqueued_jobs to run inline
      perform_enqueued_jobs do
        post callback_path(account_id: @account.id),
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-OpenClaw-Signature" => signature
             }
      end

      assert_response :ok
    end

    test "accepts callback without token verification when no token set" do
      @account.update!(api_token: nil)

      perform_enqueued_jobs do
        post callback_path(account_id: @account.id),
             params: { message: "test" }.to_json,
             headers: { "Content-Type" => "application/json" }
      end

      assert_response :ok
    end
  end
end
