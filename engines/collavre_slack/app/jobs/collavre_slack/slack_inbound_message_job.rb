module CollavreSlack
  class SlackInboundMessageJob < ApplicationJob
    queue_as :default

    def perform(payload)
      data = payload.with_indifferent_access
      creative = Collavre::Creative.find(data[:creative_id])
      user = Collavre.user_class.find_by(id: data[:user_id])
      slack_display_name = data[:slack_display_name]
      channel_link = SlackChannelLink.find_by(id: data[:slack_channel_link_id])

      return unless creative && channel_link

      # If user not found or doesn't have permission, notify admins
      unless user && creative.has_permission?(user, :feedback)
        notify_admins_about_unmapped_user(
          creative: creative,
          channel_link: channel_link,
          slack_display_name: slack_display_name,
          content: data[:content]
        )
        return
      end

      comment = Collavre::Comment.new(
        creative: creative,
        user: user,
        content: data[:content]
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

    def notify_admins_about_unmapped_user(creative:, channel_link:, slack_display_name:, content:)
      # Find admin users: owner + users with admin permission
      admin_user_ids = [ creative.user_id ]

      # Add users with admin shares on this creative or its ancestors
      creative.self_and_ancestors.each do |c|
        admin_shares = Collavre::CreativeShare.where(creative: c, permission: :admin)
        admin_user_ids.concat(admin_shares.pluck(:user_id))
      end

      admin_user_ids = admin_user_ids.compact.uniq

      # Create inbox item for each admin
      admin_user_ids.each do |admin_id|
        Collavre::InboxItem.create!(
          owner_id: admin_id,
          creative: creative,
          message_key: "collavre_slack.inbox.unmapped_user_message",
          message_params: {
            slack_user: slack_display_name || I18n.t("collavre_slack.messages.anonymous"),
            channel_name: channel_link.channel_name,
            content_preview: content.to_s.truncate(100)
          },
          link: Collavre::Engine.routes.url_helpers.creative_url(
            creative,
            Rails.application.config.action_mailer.default_url_options
          )
        )
      end

      Rails.logger.info("[CollavreSlack] Notified #{admin_user_ids.size} admins about unmapped Slack user: #{slack_display_name}")
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] Failed to notify admins: #{e.message}")
    end
  end
end
