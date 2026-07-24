require_relative "../test_helper"

module CollavreSlack
  class SlackIntegrationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @routes = CollavreSlack::Engine.routes
      @user = create_user(email: "integration@example.com", name: "Integration User")
      @creative = create_creative(@user)
      @slack_account = SlackAccount.create!(
        user: @user,
        team_id: "T123",
        team_name: "Test Team",
        access_token: "xoxb-integration-token"
      )
    end

    test "index returns all channels across multiple pages" do
      sign_in_as(@user)

      page1 = [
        { id: "C01", name: "general" },
        { id: "C02", name: "random" }
      ]
      page2 = [
        { id: "C03", name: "engineering" },
        { id: "C04", name: "design" }
      ]

      # Page 1
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: { "limit" => "200", "types" => "public_channel,private_channel" })
        .to_return(
          status: 200,
          body: { ok: true, channels: page1, response_metadata: { next_cursor: "cursor_2" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Page 2
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("cursor" => "cursor_2"))
        .to_return(
          status: 200,
          body: { ok: true, channels: page2, response_metadata: { next_cursor: "" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      get CollavreSlack::Engine.routes.url_helpers.creative_slack_integrations_path(@creative),
          headers: { "Accept" => "application/json" }

      assert_response :success

      data = JSON.parse(response.body)
      assert data["connected"]
      assert_equal 4, data["channels"].size
      assert_equal %w[C01 C02 C03 C04], data["channels"].map { |c| c["id"] }
    end

    test "index returns not connected when user has no Slack account" do
      # Remove the Slack account so the same user has no Slack connection
      @slack_account.destroy!
      sign_in_as(@user)

      get CollavreSlack::Engine.routes.url_helpers.creative_slack_integrations_path(@creative),
          headers: { "Accept" => "application/json" }

      assert_response :success

      data = JSON.parse(response.body)
      assert_not data["connected"]
      assert_equal [], data["channels"]
    end

    test "index returns channels and existing links" do
      sign_in_as(@user)

      link = SlackChannelLink.create!(
        creative: @creative.effective_origin,
        slack_account: @slack_account,
        channel_id: "C01",
        channel_name: "general",
        created_by: @user
      )

      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("limit" => "200"))
        .to_return(
          status: 200,
          body: { ok: true, channels: [ { id: "C01", name: "general" }, { id: "C02", name: "random" } ], response_metadata: { next_cursor: "" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      get CollavreSlack::Engine.routes.url_helpers.creative_slack_integrations_path(@creative),
          headers: { "Accept" => "application/json" }

      assert_response :success

      data = JSON.parse(response.body)
      assert_equal 2, data["channels"].size
      assert_equal 1, data["links"].size
      assert_equal "C01", data["links"].first["channel_id"]
    end

    test "badge returns only linked channel names without Slack API call" do
      sign_in_as(@user)

      SlackChannelLink.create!(
        creative: @creative.effective_origin,
        slack_account: @slack_account,
        channel_id: "C01",
        channel_name: "general",
        created_by: @user
      )

      # No Slack API stubs — badge should NOT call Slack API
      get CollavreSlack::Engine.routes.url_helpers.badge_creative_slack_integrations_path(@creative),
          headers: { "Accept" => "application/json" }

      assert_response :success

      data = JSON.parse(response.body)
      assert_equal 1, data["links"].size
      assert_equal "general", data["links"].first["channel_name"]
      assert_nil data["channels"]
      assert_nil data["connected"]
    end

    test "badge returns empty links when no channel is linked" do
      sign_in_as(@user)

      get CollavreSlack::Engine.routes.url_helpers.badge_creative_slack_integrations_path(@creative),
          headers: { "Accept" => "application/json" }

      assert_response :success

      data = JSON.parse(response.body)
      assert_equal 0, data["links"].size
    end

    test "index handles Slack API error gracefully" do
      sign_in_as(@user)

      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("limit" => "200"))
        .to_return(
          status: 200,
          body: { ok: false, error: "invalid_auth" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      get CollavreSlack::Engine.routes.url_helpers.creative_slack_integrations_path(@creative),
          headers: { "Accept" => "application/json" }

      assert_response :success

      data = JSON.parse(response.body)
      assert data["connected"]
      assert_equal [], data["channels"]
    end
  end
end
