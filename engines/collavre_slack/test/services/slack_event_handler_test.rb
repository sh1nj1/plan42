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
    test "imports foreign bot messages without a Slack user and ignores our bot" do
      user = create_user(email: "bots@example.com")
      creative = create_creative(user)
      account = SlackAccount.create!(user: user, team_id: "TBOTS", team_name: "Bots", access_token: "token")
      link = SlackChannelLink.create!(creative: creative, slack_account: account,
        channel_id: "CBOTS", channel_name: "geeknews", created_by: user)
      stub_request(:post, "https://slack.com/api/auth.test")
        .to_return(status: 200, body: { ok: true, bot_id: "BSELF", user_id: "USELF" }.to_json)
      payload = { type: "event_callback", team_id: "TBOTS", event: {
        type: "message", subtype: "bot_message", channel: "CBOTS", bot_id: "BNEWS",
        username: "GeekNews", text: "New article", ts: "123.456"
      } }

      [ "bot_message", nil ].each do |subtype|
        payload[:event][:subtype] = subtype
        result = SlackEventHandler.new(payload: payload).call
        assert_equal creative.id, result[:creative_id]
        assert_equal link.id, result[:slack_channel_link_id]
        assert_equal user.id, result[:user_id]
        assert_equal "GeekNews", result[:slack_display_name]
        assert_includes result[:content], "New article"
        assert_nil result[:slack_user_id]
      end
      assert_not_requested :get, "https://slack.com/api/users.info"

      payload[:event][:bot_id] = "BSELF"
      assert_nil SlackEventHandler.new(payload: payload).call
      payload[:event][:subtype] = "bot_message"
      assert_nil SlackEventHandler.new(payload: payload).call

      payload[:event][:bot_id] = "BNEWS"
      payload[:event][:subtype] = "channel_join"
      assert_nil SlackEventHandler.new(payload: payload).call
    end

    test "syncs foreign bot edits but ignores our own edits" do
      user = create_user(email: "bot-edits@example.com")
      creative = create_creative(user)
      account = SlackAccount.create!(user: user, team_id: "TEDITS", team_name: "Edits", access_token: "token")
      link = SlackChannelLink.create!(creative: creative, slack_account: account,
        channel_id: "CEDITS", channel_name: "geeknews", created_by: user)
      comment = Collavre::Comment.create!(creative: creative, user: user, content: "Original")
      SlackCommentLink.create!(comment: comment, slack_channel_link: link, message_ts: "123.456")
      stub_request(:post, "https://slack.com/api/auth.test")
        .to_return(status: 200, body: { ok: true, bot_id: "BSELF", user_id: "USELF" }.to_json)
      payload = { type: "event_callback", team_id: "TEDITS", event: {
        type: "message", subtype: "message_changed", channel: "CEDITS",
        message: { bot_id: "BNEWS", text: "Updated article", ts: "123.456" }
      } }
      result = SlackEventHandler.new(payload: payload).call
      assert_equal :message_updated, result[:type]
      assert_equal comment.id, result[:comment_id]
      assert_equal "Updated article", result[:content]

      payload[:event][:message][:bot_id] = "BSELF"
      assert_nil SlackEventHandler.new(payload: payload).call
    end
  end
end
