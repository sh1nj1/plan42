require "test_helper"

module CollavreOpenclaw
  class CallbacksControllerTest < ActionDispatch::IntegrationTest
    def callback_path(user_id:)
      "/openclaw/callback/#{user_id}"
    end

    setup do
      @user = User.create!(
        email: "test-openclaw@example.com",
        password: "password123",
        name: "Test Bot",
        gateway_url: "https://test-gateway.com"
      )
    end

    teardown do
      PendingCallback.delete_all
      @user&.destroy
    end

    test "returns not_found for non-existent user" do
      post callback_path(user_id: 999999),
           params: { message: "test" }.to_json,
           headers: { "Content-Type" => "application/json" }

      assert_response :not_found
      json = JSON.parse(response.body)
      assert_equal "User not found", json["error"]
    end

    test "returns unauthorized without nonce" do
      post callback_path(user_id: @user.id),
           params: { message: "test" }.to_json,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      json = JSON.parse(response.body)
      assert_equal "Nonce required for callback authentication", json["error"]
    end

    test "returns bad_request for invalid JSON" do
      post callback_path(user_id: @user.id),
           params: "not valid json {{{",
           headers: { "Content-Type" => "application/json" }

      assert_response :bad_request
      json = JSON.parse(response.body)
      assert_equal "Invalid JSON", json["error"]
    end

    # Nonce-based authentication tests
    test "accepts valid nonce" do
      pending = PendingCallback.create_for_request(
        user: @user,
        creative_id: 123
      )

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message"
      }.to_json

      perform_enqueued_jobs do
        post callback_path(user_id: @user.id),
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

      post callback_path(user_id: @user.id),
           params: body,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      json = JSON.parse(response.body)
      assert_equal "Invalid or expired nonce", json["error"]
    end

    test "rejects expired nonce" do
      pending = PendingCallback.create_for_request(
        user: @user,
        creative_id: 123
      )
      pending.update!(expires_at: 1.hour.ago)

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message"
      }.to_json

      post callback_path(user_id: @user.id),
           params: body,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
    end

    test "rejects nonce from different user" do
      other_user = User.create!(
        email: "other-openclaw@example.com",
        password: "password123",
        name: "Other Bot",
        gateway_url: "https://other-gateway.com"
      )

      pending = PendingCallback.create_for_request(
        user: other_user,
        creative_id: 123
      )

      body = {
        type: "proactive",
        nonce: pending.nonce,
        content: "Proactive message"
      }.to_json

      post callback_path(user_id: @user.id),
           params: body,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
    ensure
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
        user: @user,
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
        post callback_path(user_id: @user.id),
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
