module CollavreSlack
  class SlackIntegrationService
    def initialize(user:, slack_account:)
      @user = user
      @slack_account = slack_account
    end

    def link_channel(creative:, channel_id:, channel_name:)
      # Check for existing inactive link and reactivate it
      existing_link = SlackChannelLink.find_by(
        creative: creative,
        channel_id: channel_id,
        is_active: false
      )

      if existing_link
        existing_link.update!(
          slack_account: slack_account,
          channel_name: channel_name,
          is_active: true
        )
        existing_link
      else
        SlackChannelLink.create!(
          creative: creative,
          slack_account: slack_account,
          channel_id: channel_id,
          channel_name: channel_name,
          created_by: user,
          is_active: true
        )
      end
    end

    def unlink_channel(link)
      link.update!(is_active: false)
    end

    private

    attr_reader :user, :slack_account
  end
end
