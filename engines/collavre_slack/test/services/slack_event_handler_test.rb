require "test_helper"

module CollavreSlack
  class SlackEventHandlerTest < ActiveSupport::TestCase
    test "normalizes thread replies and attachments" do
      user = create_user(email: "thread@example.com", name: "Thread User")
      creative = create_creative(user)
      slack_account = SlackAccount.create!(
        user: user,
        team_id: "T999",
        team_name: "Team",
        access_token: "token"
      )
      link = SlackChannelLink.create!(
        creative: creative,
        slack_account: slack_account,
        channel_id: "C123",
        channel_name: "general",
        created_by: user,
        is_active: true
      )

      payload = {
        type: "event_callback",
        team_id: "T999",
        event: {
          type: "message",
          channel: "C123",
          user: "U999",
          text: "Hello",
          ts: "1.2",
          thread_ts: "1.1",
          files: [
            { name: "spec.pdf", url_private: "https://example.com/spec.pdf" }
          ]
        }
      }

      result = SlackEventHandler.new(payload: payload).call

      assert_equal creative.id, result[:creative_id]
      assert_equal link.id, result[:slack_channel_link_id]
      assert_includes result[:content], "[Thread reply]"
      assert_includes result[:content], "Attachments:"
      assert_includes result[:content], "spec.pdf"
    end
  end
end
