require_relative "../test_helper"

module CollavreSlack
  class MentionMappingTest < ActiveSupport::TestCase
    test "maps slack mentions to collavre mentions" do
      user = create_user(email: "mention@example.com", name: "Mentioned")
      slack_account = SlackAccount.create!(
        user: user,
        team_id: "T123",
        team_name: "Team",
        access_token: "token"
      )
      SlackUserMapping.create!(
        slack_account: slack_account,
        collavre_user: user,
        slack_user_id: "U123"
      )

      text = "Hello <@U123>"
      result = MentionMapping.from_slack(text, slack_account)

      assert_equal "Hello @Mentioned:", result
    end

    test "maps collavre mentions to slack mentions" do
      user = create_user(email: "mention2@example.com", name: "Mentioned")
      slack_account = SlackAccount.create!(
        user: user,
        team_id: "T456",
        team_name: "Team",
        access_token: "token"
      )
      SlackUserMapping.create!(
        slack_account: slack_account,
        collavre_user: user,
        slack_user_id: "U456"
      )

      text = "Hello @Mentioned:"
      result = MentionMapping.to_slack(text, slack_account)

      assert_equal "Hello <@U456>", result
    end
  end
end
