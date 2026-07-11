module CollavreSlack
  class SlackInboundMessageJob < ApplicationJob
    queue_as :default

    # SlackEventsController acks Slack with 200 the instant it enqueues this job
    # (ack-before-apply), so Slack never re-delivers the event once accepted.
    # Without a retry, a transient DB contention error would park the job as a
    # failed execution and the inbound Slack message would be lost permanently.
    # Scope is narrow: only transient contention retries; a real bug still raises
    # and parks (loud, operator-visible) instead of looping.
    retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
             wait: 2.seconds, attempts: 5

    # Permanent/unprocessable failures: retrying cannot help. The referenced
    # creative/user/link was deleted, the payload can no longer deserialize, or a
    # record is structurally invalid. Discard so the queue self-heals rather than
    # looping forever.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound
    discard_on ActiveRecord::RecordInvalid

    def perform(payload)
      data = payload.with_indifferent_access

      # Idempotency guard. retry_on above re-runs the whole job on transient DB
      # errors, and this job has multiple non-atomic writes. If a completed run
      # is somehow re-delivered, reprocessing the same Slack message would create
      # a duplicate comment. The (channel_link, message_ts) pair uniquely
      # identifies the inbound message, so a matching SlackCommentLink means it
      # was already applied — no-op.
      return if slack_message_already_applied?(data)

      creative = Collavre::Creative.find(data[:creative_id])
      user = Collavre.user_class.find_by(id: data[:user_id])
      channel_link = SlackChannelLink.find_by(id: data[:slack_channel_link_id])

      return unless creative && channel_link

      comment_user = user
      slack_email = data[:slack_email]
      slack_display_name = data[:slack_display_name]

      # Case 1: User exists in Collavre but lacks permission
      if user && !creative.has_permission?(user, :feedback)
        grant_feedback_permission(creative: creative, user: user, granter: channel_link.created_by)
        Rails.logger.info("[CollavreSlack] Granted feedback permission to user #{user.id} on creative #{creative.id}")
      end

      # Case 2: User not in Collavre - invite by email
      unless user
        if slack_email.present?
          invite_user_by_email(
            creative: creative,
            email: slack_email,
            inviter: channel_link.created_by
          )
          Rails.logger.info("[CollavreSlack] Sent invitation to #{slack_email} for creative #{creative.id}")
        end

        # Use channel creator as fallback for comment
        comment_user = channel_link.created_by
      end

      # Create comment with appropriate user
      comment = Collavre::Comment.new(
        creative: creative,
        user: comment_user,
        content: format_comment_content(data[:content], user, slack_display_name)
      )

      # Mark this comment as coming from Slack to prevent loop
      comment.instance_variable_set(:@from_slack, true)

      response = Collavre::Comments::CommandProcessor.new(comment: comment, user: user).call
      if response.present?
        comment.content = "#{comment.content}\n\n#{response}"
        comment.skip_dispatch = true  # slash command responses should not trigger AI
      end
      # Persist the comment and its Slack link atomically. Without this, a
      # transient failure on the link write (after the comment already
      # committed) would leave an orphan comment, and the retry would create a
      # second comment. In one transaction, a failed link write rolls the
      # comment back so the retry starts clean and produces exactly one comment.
      ActiveRecord::Base.transaction do
        comment.save!

        # Create link between Slack message and comment for reaction sync
        if data[:slack_channel_link_id].present? && data[:slack_message_ts].present?
          SlackCommentLink.create!(
            comment: comment,
            slack_channel_link_id: data[:slack_channel_link_id],
            message_ts: data[:slack_message_ts]
          )
        end
      end
    end

    private

    def slack_message_already_applied?(data)
      return false unless data[:slack_channel_link_id].present? && data[:slack_message_ts].present?

      SlackCommentLink.exists?(
        slack_channel_link_id: data[:slack_channel_link_id],
        message_ts: data[:slack_message_ts]
      )
    end

    def grant_feedback_permission(creative:, user:, granter:)
      # Check if share already exists
      existing_share = Collavre::CreativeShare.find_by(creative: creative, user: user)
      return if existing_share && existing_share.permission_level >= Collavre::CreativeShare.permissions[:feedback]

      if existing_share
        existing_share.update!(permission: :feedback)
      else
        Collavre::CreativeShare.create!(
          creative: creative,
          user: user,
          permission: :feedback,
          shared_by: granter
        )
      end
    end

    def invite_user_by_email(creative:, email:, inviter:)
      # Check if invitation already exists
      existing_invitation = Collavre::Invitation.find_by(creative: creative, email: email)
      return if existing_invitation

      invitation = Collavre::Invitation.create!(
        email: email,
        inviter: inviter,
        creative: creative,
        permission: :feedback
      )
      Collavre::InvitationMailer.with(invitation: invitation).invite.deliver_later
    end

    def format_comment_content(content, user, slack_display_name)
      # If user is mapped, no prefix needed (message will show their name)
      return content if user

      # If unmapped, prepend Slack username
      if slack_display_name.present?
        prefix = I18n.t("collavre_slack.messages.slack_user_prefix", name: slack_display_name)
        "#{prefix} #{content}"
      else
        content
      end
    end
  end
end
