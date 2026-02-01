require "test_helper"

module CollavreOpenclaw
  class PendingCallbackTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(
        email: "pending-test@example.com",
        password: "password123",
        name: "Test Bot"
      )
      @account = OpenclawAccount.create!(
        user: @user,
        gateway_url: "https://test-gateway.com",
        api_token: "test-token"
      )
    end

    teardown do
      PendingCallback.delete_all
      @account&.destroy
      @user&.destroy
    end

    test "creates pending callback with nonce" do
      pending = PendingCallback.create_for_request(
        account: @account,
        creative_id: 123
      )

      assert pending.persisted?
      assert pending.nonce.present?
      assert_equal 123, pending.creative_id
      assert pending.expires_at > Time.current
    end

    test "nonce is unique" do
      pending1 = PendingCallback.create_for_request(account: @account, creative_id: 1)
      pending2 = PendingCallback.create_for_request(account: @account, creative_id: 2)

      assert_not_equal pending1.nonce, pending2.nonce
    end

    test "verify_and_consume! returns callback and deletes it" do
      pending = PendingCallback.create_for_request(
        account: @account,
        creative_id: 456,
        thread_id: 789
      )
      nonce = pending.nonce

      result = PendingCallback.verify_and_consume!(nonce)

      assert_equal pending.id, result.id
      assert_equal 456, result.creative_id
      assert_equal 789, result.thread_id
      assert_nil PendingCallback.find_by(nonce: nonce)
    end

    test "verify_and_consume! returns nil for invalid nonce" do
      result = PendingCallback.verify_and_consume!("invalid-nonce")
      assert_nil result
    end

    test "verify_and_consume! returns nil for expired nonce" do
      pending = PendingCallback.create_for_request(account: @account, creative_id: 1)
      pending.update!(expires_at: 1.hour.ago)

      result = PendingCallback.verify_and_consume!(pending.nonce)
      assert_nil result
    end

    test "cleanup_expired! removes old callbacks" do
      valid = PendingCallback.create_for_request(account: @account, creative_id: 1)
      expired = PendingCallback.create_for_request(account: @account, creative_id: 2)
      expired.update!(expires_at: 1.hour.ago)

      PendingCallback.cleanup_expired!

      assert PendingCallback.exists?(valid.id)
      assert_not PendingCallback.exists?(expired.id)
    end

    test "stores context as JSON" do
      pending = PendingCallback.create_for_request(
        account: @account,
        creative_id: 123,
        context: { extra_key: "extra_value" }
      )

      pending.reload
      assert_equal({ "extra_key" => "extra_value" }, pending.context)
    end
  end
end
