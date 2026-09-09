require_relative "../test_helper"

module CollavreSlack
  class SlackBotMessageTest < ActiveSupport::TestCase
    setup do
      @account = SlackAccount.new(id: 42, access_token: "bot-test-token")
      @cache = ActiveSupport::Cache::MemoryStore.new
      @identity_request = stub_request(:post, "https://slack.com/api/auth.test")
        .with(headers: { "Authorization" => "Bearer bot-test-token" })
        .to_return(status: 200, body: { ok: true, bot_id: "BSELF", user_id: "USELF" }.to_json)
    end

    test "rejects our bot with and without bot_message subtype" do
      [ nil, "bot_message" ].each do |subtype|
        assert own?(bot_id: "BSELF", subtype: subtype)
      end
    end

    test "rejects our bot by user ID when bot ID is absent" do
      assert own?(subtype: "bot_message", user: "USELF")
    end

    test "accepts foreign bots and ordinary human messages" do
      assert_not own?(bot_id: "BOTHER", subtype: "bot_message")
      assert_not own?(bot_id: "BOTHER", user: "UOTHER")
      assert_not own?(user: "UHUMAN")
      assert_requested @identity_request, times: 1
    end

    test "does not query identity for human messages" do
      assert_not own?(user: "UHUMAN")
      assert_not_requested @identity_request
    end

    test "retries identity resolution after an API failure" do
      stub_request(:post, "https://slack.com/api/auth.test").to_return(
        { status: 200, body: { ok: false, error: "ratelimited" }.to_json },
        { status: 200, body: { ok: true, bot_id: "BSELF", user_id: "USELF" }.to_json }
      )
      assert_raises(RuntimeError) { own?(bot_id: "BOTHER") }
      assert_not own?(bot_id: "BOTHER")
    end

    test "does not accept an incomplete identity" do
      stub_request(:post, "https://slack.com/api/auth.test")
        .to_return(status: 200, body: { ok: true, user_id: "USELF" }.to_json)
      assert_raises(RuntimeError) { own?(bot_id: "BOTHER") }
    end

    test "token rotation invalidates the identity cache" do
      assert own?(bot_id: "BSELF")
      @account.access_token = "rotated-token"
      stub_request(:post, "https://slack.com/api/auth.test")
        .with(headers: { "Authorization" => "Bearer rotated-token" })
        .to_return(status: 200, body: { ok: true, bot_id: "BNEW", user_id: "UNEW" }.to_json)
      assert own?(bot_id: "BNEW")
      assert_not own?(bot_id: "BSELF")
    end

    test "uses bot attribution without mapping to a person" do
      sender = SlackBotMessage.new(account: @account, message: {
        bot_id: "BOTHER", username: "GeekNews"
      }).sender
      assert_equal "GeekNews", sender[:slack_display_name]
      assert_nil sender[:user]
      assert_nil sender[:slack_email]
      assert_nil sender[:slack_user_id]
      assert_equal "News", SlackBotMessage.new(account: @account, message: {
        bot_id: "BOTHER", bot_profile: { name: "News" }
      }).sender[:slack_display_name]
      assert_equal "BOTHER", SlackBotMessage.new(account: @account, message: {
        bot_id: "BOTHER"
      }).sender[:slack_display_name]
    end

    private

    def own?(message)
      Rails.stub(:cache, @cache) do
        SlackBotMessage.new(account: @account, message: message).own?
      end
    end
  end
end
