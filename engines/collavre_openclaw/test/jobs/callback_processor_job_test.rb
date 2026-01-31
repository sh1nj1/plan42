require "test_helper"

module CollavreOpenclaw
  class CallbackProcessorJobTest < ActiveJob::TestCase
    setup do
      @user = User.create!(
        email: "job-test@example.com",
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
      @account&.destroy
      @user&.destroy
    end

    test "skips processing for non-existent account" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(999999, { type: "response" })
      end
    end

    test "handles response type payload" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@account.id, {
          type: "response",
          content: "AI response content",
          context: { task_id: 123 }
        })
      end
    end

    test "handles error type payload" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@account.id, {
          type: "error",
          error: "Something went wrong"
        })
      end
    end

    test "handles unknown callback type gracefully" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@account.id, {
          type: "unknown_type",
          data: "some data"
        })
      end
    end

    test "processes payload with symbolized keys" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@account.id, {
          type: :response,
          content: "Response with symbol keys"
        })
      end
    end
  end
end
