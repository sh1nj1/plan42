require_relative "test_helper"

# The mock decision is read by three callers (OmniAuth middleware, NotionClient,
# NotionAuthController) and it used to be made twice, from different inputs.
# These pin the single answer, including the two ways the second copy got it
# wrong: a client id that lives anywhere but ENV, and NOTION_MOCK being ignored.
class CollavreNotionMockPolicyTest < ActiveSupport::TestCase
  setup do
    @account = CollavreNotion::NotionAccount.new(token: "tok", notion_uid: "uid")
  end

  test "a client id configured outside ENV keeps Notion on the real API" do
    # The admin UI writes to integration_settings; Rails credentials are the
    # other non-ENV home. Reading ENV["NOTION_CLIENT_ID"] alone called this
    # developer uncredentialled and sent their API calls to localhost:4568.
    Collavre::IntegrationSetting.create!(key: "notion_client_id", category: "notion_oauth", value: "from-admin-ui")

    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil) do
      assert_equal "from-admin-ui", CollavreNotion.client_id
      assert_not CollavreNotion.mock_enabled?, "credentials exist — nothing to stand in for"
      assert_equal CollavreNotion::NotionClient::DEFAULT_BASE_URL, base_url
    end
  end

  test "NOTION_MOCK=0 disables the mock that would otherwise auto-enable" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => "0") do
      assert_not CollavreNotion.mock_enabled?
      assert_equal CollavreNotion::NotionClient::DEFAULT_BASE_URL, base_url,
        "the documented disable path has to reach API calls, not just the login"
    end
  end

  test "NOTION_MOCK=1 enables the mock even with credentials present" do
    in_env("development", "NOTION_CLIENT_ID" => "real-id", "NOTION_MOCK" => "1") do
      assert CollavreNotion.mock_enabled?
      assert_equal CollavreNotion::NotionClient::MOCK_SERVER_DEFAULT, base_url
    end
  end

  test "no credentials in development auto-enables the mock" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil) do
      assert CollavreNotion.mock_enabled?
      assert_equal CollavreNotion::NotionClient::MOCK_SERVER_DEFAULT, base_url
    end
  end

  test "production never mocks, whatever the setting says" do
    in_env("production", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => "1") do
      assert_not CollavreNotion.mock_enabled?,
        "a deployed host must not be switchable into fixed-identity auth by an env var"
      assert_equal CollavreNotion::NotionClient::DEFAULT_BASE_URL, base_url
    end
  end

  test "an explicit endpoint still wins over the mock decision" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil,
           "NOTION_API_ENDPOINT" => "http://notion.test/v1") do
      assert_equal "http://notion.test/v1", base_url
    end
  end

  private

  def base_url
    CollavreNotion::NotionClient.new(@account).instance_variable_get(:@base_url)
  end

  def in_env(rails_env, vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    # Non-sensitive keys are memoized in Rails.cache for 5 minutes, and the test
    # store is a memory store — without this the second case reads the first's answer.
    Rails.cache.clear

    Rails.stub(:env, ActiveSupport::StringInquirer.new(rails_env)) { yield }
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rails.cache.clear
  end
end
