module CollavreSlack
  class SlackIntegrationService
    def initialize(user:, slack_account:)
      @user = user
      @slack_account = slack_account
    end

    def link_channel(creative:, channel_id:, channel_name:)
      SlackChannelLink.create!(
        creative: creative,
        slack_account: slack_account,
        channel_id: channel_id,
        channel_name: channel_name,
        created_by: user,
        is_active: true
      )
    end

    def unlink_channel(link)
      link.update!(is_active: false)
    end

    def list_channels
      slack_client.list_channels
    end

    private

    attr_reader :user, :slack_account

    def slack_client
      @slack_client ||= SlackClient.new(access_token: slack_account.access_token)
    end
  end
end
