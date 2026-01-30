module CollavreSlack
  module SlackDispatchable
    extend ActiveSupport::Concern

    included do
      after_create_commit :dispatch_to_slack_channels
      after_update_commit :update_slack_messages, if: :saved_change_to_content?
      before_destroy :prepare_slack_message_deletion
      after_destroy_commit :delete_slack_messages
    end

    private

    def dispatch_to_slack_channels
      # Don't dispatch if this comment came from Slack (prevent loop)
      if instance_variable_get(:@from_slack)
        Rails.logger.info("[CollavreSlack] Skipping dispatch - comment came from Slack")
        return
      end

      # Use effective_origin since Slack links are on origin creative
      target_creative_id = creative.effective_origin.id

      return unless CollavreSlack::SlackChannelLink.where(creative_id: target_creative_id, is_active: true).exists?

      Rails.logger.info("[CollavreSlack] dispatch_to_slack_channels called for comment #{id}, creative_id=#{creative_id}, target_creative_id=#{target_creative_id}")

      links = CollavreSlack::SlackChannelLink.where(creative_id: target_creative_id, is_active: true)
      Rails.logger.info("[CollavreSlack] Found #{links.count} active Slack links")

      links.find_each do |link|
        Rails.logger.info("[CollavreSlack] Dispatching to channel #{link.channel_name} (#{link.channel_id})")
        dispatcher = CollavreSlack::SlackMessageDispatcher.new(channel_link: link)
        message_text = content.to_plain_text rescue content.to_s
        sender_name = user&.name || "Anonymous"
        dispatcher.enqueue(message: "[#{sender_name}] #{message_text}", sender: user, comment: self)
      end
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] Failed to dispatch to Slack: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end

    def update_slack_messages
      return if instance_variable_get(:@from_slack)

      comment_links = CollavreSlack::SlackCommentLink.where(comment_id: id)
      return if comment_links.empty?

      message_text = content.to_plain_text rescue content.to_s
      sender_name = user&.name || "Anonymous"
      formatted_message = "[#{sender_name}] #{message_text}"

      comment_links.each do |link|
        CollavreSlack::SlackMessageUpdateJob.perform_later(
          slack_comment_link_id: link.id,
          message: formatted_message
        )
      end
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] Failed to update Slack messages: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end

    def prepare_slack_message_deletion
      Rails.logger.info("[CollavreSlack] prepare_slack_message_deletion called for comment #{id}")
      return if instance_variable_get(:@from_slack)

      # Save link info before the comment is deleted
      # The database will cascade delete the records, but we need the info for Slack API
      comment_links = CollavreSlack::SlackCommentLink.where(comment_id: id)
      Rails.logger.info("[CollavreSlack] Found #{comment_links.count} slack comment links")
      @slack_links_to_delete = comment_links.map do |link|
        { slack_channel_link_id: link.slack_channel_link_id, message_ts: link.message_ts }
      end
      Rails.logger.info("[CollavreSlack] Saved #{@slack_links_to_delete.size} links for deletion")
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] Failed to prepare Slack message deletion: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end

    def delete_slack_messages
      Rails.logger.info("[CollavreSlack] delete_slack_messages called")
      return if instance_variable_get(:@from_slack)

      links_to_delete = instance_variable_get(:@slack_links_to_delete) || []
      Rails.logger.info("[CollavreSlack] Links to delete: #{links_to_delete.size}")
      return if links_to_delete.empty?

      links_to_delete.each do |link_info|
        Rails.logger.info("[CollavreSlack] Enqueuing SlackMessageDeleteJob for ts=#{link_info[:message_ts]}")
        CollavreSlack::SlackMessageDeleteJob.perform_later(
          slack_channel_link_id: link_info[:slack_channel_link_id],
          message_ts: link_info[:message_ts]
        )
      end
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] Failed to delete Slack messages: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end
  end
end
