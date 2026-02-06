module CollavreSlack
  class SlackInboundMessageJob < ApplicationJob
    queue_as :default

    def perform(payload)
      data = payload.with_indifferent_access
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
      comment.content = "#{comment.content}\n\n#{response}" if response.present?
      comment.save!

      # Dispatch system event to trigger AI agents (same as CommentsController#create)
      unless comment.private?
        Collavre::SystemEvents::Dispatcher.dispatch("comment_created", {
          comment: {
            id: comment.id,
            content: comment.content,
            user_id: comment.user_id
          },
          creative: {
            id: creative.id,
            description: creative.description
          },
          topic: {
            id: comment.topic_id
          },
          chat: {
            content: comment.content
          }
        })
      end

      # Create link between Slack message and comment for reaction sync
      if data[:slack_channel_link_id].present? && data[:slack_message_ts].present?
        SlackCommentLink.create!(
          comment: comment,
          slack_channel_link_id: data[:slack_channel_link_id],
          message_ts: data[:slack_message_ts]
        )
      end
    end

    private

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
