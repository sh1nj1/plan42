require "test_helper"

module CollavreOpenclaw
  class CallbacksControllerTest < ActionDispatch::IntegrationTest
    # Define only the needed URL helpers to avoid test_ prefixed helpers being detected as test methods
    def callback_path(account_id:)
      "/openclaw/callback/#{account_id}"
    end

    setup do
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
      PendingCallback.delete_all
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

    test "returns unauthorized for missing auth when token is set" do
      post callback_path(account_id: @account.id),
           params: { message: "test" }.to_json,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      json = JSON.parse(response.body)
      assert_equal "Unauthorized", json["error"]
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
    end

    test "accepts valid HMAC signature" do
      body = { message: "test", content: "Hello from OpenClaw" }.to_json
      signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret-token", body)

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

    test "accepts valid Bearer token" do
      body = { message: "test", content: "Hello from OpenClaw" }.to_json

      perform_enqueued_jobs do
        post callback_path(account_id: @account.id),
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "Authorization" => "Bearer test-secret-token"
             }
      end

      assert_response :ok
    end

    test "rejects invalid Bearer token" do
      body = { message: "test" }.to_json

      post callback_path(account_id: @account.id),
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "Authorization" => "Bearer wrong-token"
           }

      assert_response :unauthorized
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

    test "returns bad_request for invalid JSON" do
      post callback_path(account_id: @account.id),
           params: "not valid json {{{",
           headers: {
             "Content-Type" => "application/json",
             "Authorization" => "Bearer test-secret-token"
           }

      assert_response :bad_request
      json = JSON.parse(response.body)
      assert_equal "Invalid JSON", json["error"]
    end

    # Nonce-based authentication tests
    test "accepts valid nonce" do
      pending = PendingCallback.create_for_request(
        account: @account,
        creative_id: 123
      )

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message"
      }.to_json

      perform_enqueued_jobs do
        post callback_path(account_id: @account.id),
             params: body,
             headers: { "Content-Type" => "application/json" }
      end

      assert_response :ok
      # Nonce should be consumed (deleted)
      assert_nil PendingCallback.find_by(nonce: pending.nonce)
    end

    test "rejects invalid nonce" do
      body = {
        type: "proactive",
        nonce: "invalid-nonce-12345",
        content: "Proactive message"
      }.to_json

      post callback_path(account_id: @account.id),
           params: body,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      json = JSON.parse(response.body)
      assert_equal "Invalid or expired nonce", json["error"]
    end

    test "rejects expired nonce" do
      pending = PendingCallback.create_for_request(
        account: @account,
        creative_id: 123
      )
      pending.update!(expires_at: 1.hour.ago)

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message"
      }.to_json

      post callback_path(account_id: @account.id),
           params: body,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
    end

    test "rejects nonce from different account" do
      other_user = User.create!(
        email: "other-openclaw@example.com",
        password: "password123",
        name: "Other Bot"
      )
      other_account = OpenclawAccount.create!(
        user: other_user,
        gateway_url: "https://other-gateway.com",
        api_token: "other-token"
      )

      pending = PendingCallback.create_for_request(
        account: other_account,
        creative_id: 123
      )

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message"
      }.to_json

      post callback_path(account_id: @account.id),
           params: body,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
    ensure
      other_account&.destroy
      other_user&.destroy
    end

    test "nonce callback merges context from pending callback" do
      owner = User.create!(
        email: "owner-test@example.com",
        password: "password123",
        name: "Owner"
      )
      creative = Collavre::Creative.create!(
        description: "Test Creative",
        user: owner
      )

      pending = PendingCallback.create_for_request(
        account: @account,
        creative_id: creative.id,
        thread_id: 999
      )

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message with context"
      }.to_json

      # The job should create a comment with merged context
      perform_enqueued_jobs do
        post callback_path(account_id: @account.id),
             params: body,
             headers: { "Content-Type" => "application/json" }
      end

      assert_response :ok

      # Verify comment was created with the context from pending callback
      comment = Collavre::Comment.last
      assert_equal creative.id, comment.creative_id
      assert_equal "Proactive message with context", comment.content
    ensure
      Collavre::Comment.where(creative: creative).destroy_all
      creative&.destroy
      owner&.destroy
    end
  end
end
