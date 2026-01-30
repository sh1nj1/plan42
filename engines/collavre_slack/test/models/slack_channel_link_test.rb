require "test_helper"

module CollavreSlack
  class SlackChannelLinkTest < ActiveSupport::TestCase
    test "enforces unique creative/channel pairing" do
      user = create_user(email: "link@example.com", name: "Link User")
      creative = create_creative(user)
      slack_account = SlackAccount.create!(
        user: user,
        team_id: "T777",
        team_name: "Team",
        access_token: "token"
      )

      SlackChannelLink.create!(
        creative: creative,
        slack_account: slack_account,
        channel_id: "C777",
        channel_name: "general",
        created_by: user,
        is_active: true
      )

      duplicate = SlackChannelLink.new(
        creative: creative,
        slack_account: slack_account,
        channel_id: "C777",
        channel_name: "general",
        created_by: user,
        is_active: true
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:creative_id], "has already been taken"
    end
  end
end
