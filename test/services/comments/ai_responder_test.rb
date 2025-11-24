require "test_helper"

module Comments
  class AiResponderTest < ActiveSupport::TestCase
    test "updates placeholder with error when AI client fails" do
      creative = creatives(:tshirt)
      commenter = users(:one)
      ai_user = User.create!(
        name: "AIBot",
        email: "aibot@example.com",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-2.5-flash",
        system_prompt: "You are a bot.",
        llm_api_key: "dummy-key",
        email_verified_at: Time.current
      )

      comment = creative.comments.create!(content: "@AIBot: ping", user: commenter)

      failing_client = Minitest::Mock.new
      failing_client.expect(:chat, nil) do |_messages, &block|
        raise StandardError, "boom"
      end

      AiClient.stub(:new, failing_client) do
        Comments::AiResponder.new(comment: comment, creative: creative).call
      end

      reply = creative.comments.where(user: ai_user).order(:id).last
      assert_equal "AI Error: boom", reply.content
    end
  end
end
