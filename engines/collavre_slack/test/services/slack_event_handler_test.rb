require_relative "../test_helper"

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
        created_by: user
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

      # Stub Slack users.info API call for unknown user mapping
      stub_request(:get, "https://slack.com/api/users.info")
        .with(query: hash_including("user" => "U999"))
        .to_return(
          status: 200,
          body: { ok: true, user: { id: "U999", name: "slackuser", profile: { display_name: "Slack User", real_name: "Slack User" } } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = SlackEventHandler.new(payload: payload).call

      assert_equal creative.id, result[:creative_id]
      assert_equal link.id, result[:slack_channel_link_id]
      assert_includes result[:content], I18n.t("collavre_slack.messages.thread_reply")
      assert_includes result[:content], I18n.t("collavre_slack.messages.attachments")
      assert_includes result[:content], "spec.pdf"
    end
  end
end
