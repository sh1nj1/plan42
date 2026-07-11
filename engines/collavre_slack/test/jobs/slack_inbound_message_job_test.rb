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

    test "invites user when Slack user is not in Collavre" do
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

      # Should create invitation
      assert_difference "Collavre::Invitation.count", 1 do
        # Should create comment (with channel creator as user)
        assert_difference "Collavre::Comment.count", 1 do
          SlackInboundMessageJob.perform_now(payload)
        end
      end

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

      creative_comment_count = @creative.comments.count

      # Should create a share (granting permission)
      assert_difference "Collavre::CreativeShare.count", 1 do
        SlackInboundMessageJob.perform_now(payload)
      end

      # Check permission was granted
      share = Collavre::CreativeShare.find_by(creative: @creative, user: slack_user)
      assert_equal "feedback", share.permission

      # Check comment was created with the Slack user on this creative
      assert_equal creative_comment_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
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

      creative_comment_count = @creative.comments.count

      # Should not create additional share
      assert_no_difference "Collavre::CreativeShare.count" do
        SlackInboundMessageJob.perform_now(payload)
      end

      assert_equal creative_comment_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
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

    test "invite email enqueue failure rolls back the invitation and retry delivers exactly once" do
      # An unmapped Slack user triggers invite_user_by_email. deliver_later enqueues
      # synchronously (enqueue_after_transaction_commit is false), so a transient
      # Deadlocked on the Solid Queue enqueue INSERT must roll back the invitation
      # create with it — otherwise a committed invitation with a failed enqueue
      # would, on retry, hit the existing-invitation guard and never send the email.
      payload = {
        creative_id: @creative.id,
        user_id: nil,
        content: "invite me",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1700000000.909090",
        slack_display_name: "Atomic User",
        slack_email: "atomic@slack.com",
        slack_user_id: "U909"
      }

      deliver_calls = 0
      fake_message = Object.new
      fake_message.define_singleton_method(:deliver_later) do
        deliver_calls += 1
        raise ActiveRecord::Deadlocked, "enqueue deadlock" if deliver_calls == 1

        :enqueued
      end
      fake_mailer = Object.new
      fake_mailer.define_singleton_method(:invite) { fake_message }

      # The first enqueue deadlocks (rolling back its invitation create), the
      # second succeeds — net exactly one invitation persisted.
      Collavre::InvitationMailer.stub(:with, ->(**_kwargs) { fake_mailer }) do
        assert_difference "Collavre::Invitation.count", 1 do
          SlackInboundMessageJob.perform_now(payload)
        end
      end

      assert_equal 2, deliver_calls, "enqueue should be retried once after the transient deadlock"
      assert_equal 1, Collavre::Invitation.where(email: "atomic@slack.com", creative: @creative).count,
                   "the rolled-back first attempt must leave no orphan invitation"
    end

    test "reprocessing the same Slack message does not create a duplicate comment" do
      slack_user = create_user(email: "idem@example.com", name: "Idem User")
      Collavre::CreativeShare.create!(creative: @creative, user: slack_user, permission: :feedback)

      payload = {
        creative_id: @creative.id,
        user_id: slack_user.id,
        content: "Only once please",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1700000000.000001",
        slack_display_name: "Idem User",
        slack_email: "idem@example.com",
        slack_user_id: "U555"
      }

      creative_comment_count = @creative.comments.count
      SlackInboundMessageJob.perform_now(payload)
      assert_equal creative_comment_count + 1, @creative.comments.reload.count
      assert_equal 1, CollavreSlack::SlackCommentLink.where(slack_channel_link_id: @channel_link.id, message_ts: "1700000000.000001").count

      # A retry / redelivery of the same message (same channel_link + ts) is a no-op:
      # no duplicate comment on the creative and no duplicate Slack link.
      assert_no_difference [ "@creative.comments.count", "CollavreSlack::SlackCommentLink.count" ] do
        SlackInboundMessageJob.perform_now(payload)
      end
    end

    test "retries only the write on transient deadlock and runs commands exactly once" do
      slack_user = create_user(email: "retry@example.com", name: "Retry User")
      Collavre::CreativeShare.create!(creative: @creative, user: slack_user, permission: :feedback)

      payload = {
        creative_id: @creative.id,
        user_id: slack_user.id,
        content: "retry me",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1700000000.777777",
        slack_display_name: "Retry User",
        slack_email: "retry@example.com",
        slack_user_id: "U777"
      }

      # CommandProcessor has non-idempotent side effects; it must run exactly once
      # even when the final write is retried after a transient deadlock.
      command_calls = 0
      fake_processor = Object.new
      fake_processor.define_singleton_method(:call) do
        command_calls += 1
        nil
      end

      # First link write deadlocks, second succeeds — exercises the in-place
      # write retry (not a whole-job retry).
      create_calls = 0
      original_create = CollavreSlack::SlackCommentLink.method(:create!)

      Collavre::Comments::CommandProcessor.stub(:new, ->(**) { fake_processor }) do
        CollavreSlack::SlackCommentLink.stub(:create!, ->(**kwargs) {
          create_calls += 1
          raise ActiveRecord::Deadlocked, "deadlock victim" if create_calls == 1

          original_create.call(**kwargs)
        }) do
          creative_comment_count = @creative.comments.count
          SlackInboundMessageJob.perform_now(payload)
          assert_equal creative_comment_count + 1, @creative.comments.reload.count
        end
      end

      assert_equal 2, create_calls, "write should be retried once after the deadlock"
      assert_equal 1, command_calls, "CommandProcessor must run exactly once despite the write retry"
      assert_equal 1, CollavreSlack::SlackCommentLink.where(
        slack_channel_link_id: @channel_link.id, message_ts: "1700000000.777777"
      ).count
    end

    test "retries the pre-command permission grant on transient deadlock" do
      # The permission grant runs before CommandProcessor and is not covered by a
      # job-level retry_on. A transient deadlock there must be retried in place —
      # otherwise the already-acked Slack message would be lost.
      slack_user = create_user(email: "grantretry@example.com", name: "Grant Retry")

      payload = {
        creative_id: @creative.id,
        user_id: slack_user.id,
        content: "grant then comment",
        slack_channel_link_id: @channel_link.id,
        slack_message_ts: "1700000000.888888",
        slack_display_name: "Grant Retry",
        slack_email: "grantretry@example.com",
        slack_user_id: "U888"
      }

      grant_calls = 0
      original_create = Collavre::CreativeShare.method(:create!)

      creative_comment_count = @creative.comments.count
      Collavre::CreativeShare.stub(:create!, ->(*args, **kwargs) {
        grant_calls += 1
        raise ActiveRecord::Deadlocked, "deadlock victim" if grant_calls == 1

        original_create.call(*args, **kwargs)
      }) do
        SlackInboundMessageJob.perform_now(payload)
      end

      assert_equal 2, grant_calls, "permission grant should be retried once after the deadlock"
      # Message was not lost: permission granted and comment created.
      share = Collavre::CreativeShare.find_by(creative: @creative, user: slack_user)
      assert_equal "feedback", share.permission
      assert_equal creative_comment_count + 1, @creative.comments.reload.count
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

      # Should still create comment but no invitation (no email to invite)
      assert_no_difference "Collavre::Invitation.count" do
        assert_difference "Collavre::Comment.count", 1 do
          SlackInboundMessageJob.perform_now(payload)
        end
      end

      # Check comment is prefixed with Slack username
      comment = Collavre::Comment.last
      assert_includes comment.content, "[Slack: @No Email User]"
    end
  end
end
