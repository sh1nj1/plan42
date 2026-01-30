require_relative "../test_helper"

module CollavreSlack
  class SlackInboundMessageJobTest < ActiveSupport::TestCase
    setup do
      @owner = create_user(email: "owner@example.com", name: "Owner")
      @creative = create_creative(@owner)
      @slack_account = SlackAccount.create!(
        user: @owner,
        team_id: "T123",
        team_name: "Test Team",
        access_token: "xoxb-test-token"
      )
      @channel_link = SlackChannelLink.create!(
        creative: @creative,
        slack_account: @slack_account,
        channel_id: "C123",
        channel_name: "test-channel",
        created_by: @owner
      )
    end

    test "notifies admins when Slack user is not in Collavre" do
      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "Hello from Slack!",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "John Doe",
        slack_email: "john@slack.com",
        slack_user_id: "U999"
      }

      assert_difference "Collavre::InboxItem.count", 1 do
        SlackInboundMessageJob.perform_now(payload)
      end

      inbox_item = Collavre::InboxItem.last
      assert_equal @owner.id, inbox_item.owner_id
      assert_equal @creative.id, inbox_item.creative_id
      assert_equal "collavre_slack.inbox.unmapped_user_message", inbox_item.message_key
      assert_equal "John Doe (john@slack.com)", inbox_item.message_params["slack_user"]
      assert_equal "test-channel", inbox_item.message_params["channel_name"]
    end

    test "notifies admins when Slack user lacks feedback permission" do
      # Create a user that exists but has no permission on the creative
      slack_user = create_user(email: "noperm@example.com", name: "No Permission")

      payload = {
        creative_id: @creative.id,
        user_id: slack_user.id,
        content: "Hello from Slack!",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "No Permission",
        slack_email: "noperm@example.com",
        slack_user_id: "U888"
      }

      # User exists but has no permission - should notify admin
      assert_difference "Collavre::InboxItem.count", 1 do
        SlackInboundMessageJob.perform_now(payload)
      end

      # No comment should be created
      assert_equal 0, Collavre::Comment.where(creative: @creative, user: slack_user).count
    end

    test "creates comment when Slack user has feedback permission" do
      # Create a user with feedback permission
      slack_user = create_user(email: "feedback@example.com", name: "Feedback User")
      Collavre::CreativeShare.create!(
        creative: @creative,
        user: slack_user,
        permission: :feedback
      )

      payload = {
        creative_id: @creative.id,
        user_id: slack_user.id,
        content: "Hello from Slack!",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "Feedback User",
        slack_email: "feedback@example.com",
        slack_user_id: "U777"
      }

      # Count inbox items with our specific message key before
      unmapped_inbox_count_before = Collavre::InboxItem.where(message_key: "collavre_slack.inbox.unmapped_user_message").count

      assert_difference "Collavre::Comment.count", 1 do
        SlackInboundMessageJob.perform_now(payload)
      end

      # Should not create an unmapped user inbox notification
      unmapped_inbox_count_after = Collavre::InboxItem.where(message_key: "collavre_slack.inbox.unmapped_user_message").count
      assert_equal unmapped_inbox_count_before, unmapped_inbox_count_after

      comment = Collavre::Comment.last
      assert_equal slack_user.id, comment.user_id
      assert_equal "Hello from Slack!", comment.content
    end

    test "formats slack user label with name and email" do
      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "Test message",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "Jane Smith",
        slack_email: "jane@company.com",
        slack_user_id: "U555"
      }

      SlackInboundMessageJob.perform_now(payload)

      inbox_item = Collavre::InboxItem.last
      assert_equal "Jane Smith (jane@company.com)", inbox_item.message_params["slack_user"]
    end

    test "formats slack user label with only name when email is missing" do
      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "Test message",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "Anonymous User",
        slack_email: nil,
        slack_user_id: "U444"
      }

      SlackInboundMessageJob.perform_now(payload)

      inbox_item = Collavre::InboxItem.last
      assert_equal "Anonymous User", inbox_item.message_params["slack_user"]
    end

    test "formats slack user label with user_id when name is missing" do
      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "Test message",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: nil,
        slack_email: nil,
        slack_user_id: "U333"
      }

      SlackInboundMessageJob.perform_now(payload)

      inbox_item = Collavre::InboxItem.last
      assert_equal "U333", inbox_item.message_params["slack_user"]
    end
  end
end
