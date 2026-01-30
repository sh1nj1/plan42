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

    test "invites and notifies admins when Slack user is not in Collavre" do
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

      # Should create inbox notification for admin
      assert_difference "Collavre::InboxItem.count", 1 do
        # Should create invitation
        assert_difference "Collavre::Invitation.count", 1 do
          # Should create comment (with channel creator as user)
          assert_difference "Collavre::Comment.count", 1 do
            SlackInboundMessageJob.perform_now(payload)
          end
        end
      end

      # Check inbox notification
      inbox_item = Collavre::InboxItem.where(message_key: "collavre_slack.inbox.unmapped_user_message").last
      assert_equal @owner.id, inbox_item.owner_id
      assert_equal "John Doe (john@slack.com)", inbox_item.message_params["slack_user"]

      # Check invitation
      invitation = Collavre::Invitation.last
      assert_equal "john@slack.com", invitation.email
      assert_equal @creative.id, invitation.creative_id
      assert_equal "feedback", invitation.permission

      # Check comment (created with channel creator, prefixed with Slack username)
      comment = Collavre::Comment.last
      assert_equal @owner.id, comment.user_id
      assert_includes comment.content, "[Slack: @John Doe]"
    end

    test "grants permission and creates comment when Slack user lacks feedback permission" do
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

      # Should not create inbox notification (user exists in Collavre)
      assert_no_difference "Collavre::InboxItem.where(message_key: 'collavre_slack.inbox.unmapped_user_message').count" do
        # Should create a share (granting permission)
        assert_difference "Collavre::CreativeShare.count", 1 do
          # Should create comment
          assert_difference "Collavre::Comment.count", 1 do
            SlackInboundMessageJob.perform_now(payload)
          end
        end
      end

      # Check permission was granted
      share = Collavre::CreativeShare.find_by(creative: @creative, user: slack_user)
      assert_equal "feedback", share.permission

      # Check comment was created with the Slack user
      comment = Collavre::Comment.last
      assert_equal slack_user.id, comment.user_id
      assert_equal "Hello from Slack!", comment.content
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

      # Should not create additional share
      assert_no_difference "Collavre::CreativeShare.count" do
        assert_difference "Collavre::Comment.count", 1 do
          SlackInboundMessageJob.perform_now(payload)
        end
      end

      comment = Collavre::Comment.last
      assert_equal slack_user.id, comment.user_id
      assert_equal "Hello from Slack!", comment.content
    end

    test "does not send duplicate invitation" do
      # Create existing invitation
      Collavre::Invitation.create!(
        email: "existing@slack.com",
        inviter: @owner,
        creative: @creative,
        permission: :feedback
      )

      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "Test message",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "Existing User",
        slack_email: "existing@slack.com",
        slack_user_id: "U222"
      }

      # Should not create duplicate invitation
      assert_no_difference "Collavre::Invitation.count" do
        SlackInboundMessageJob.perform_now(payload)
      end
    end

    test "creates comment without invitation when email is missing" do
      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "Test message",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1234567890.123456",
        slack_display_name: "No Email User",
        slack_email: nil,
        slack_user_id: "U111"
      }

      # Should still create comment and inbox notification, but no invitation
      assert_no_difference "Collavre::Invitation.count" do
        assert_difference "Collavre::Comment.count", 1 do
          assert_difference "Collavre::InboxItem.count", 1 do
            SlackInboundMessageJob.perform_now(payload)
          end
        end
      end
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

      inbox_item = Collavre::InboxItem.where(message_key: "collavre_slack.inbox.unmapped_user_message").last
      assert_equal "Jane Smith (jane@company.com)", inbox_item.message_params["slack_user"]
    end
  end
end
