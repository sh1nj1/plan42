require_relative "test_helper"

# The mock decision is read by three callers (OmniAuth middleware, NotionClient,
# NotionAuthController) and it used to be made twice, from different inputs.
# These pin the single answer, including the two ways the second copy got it
# wrong: a client id that lives anywhere but ENV, and NOTION_MOCK being ignored.
class CollavreNotionMockPolicyTest < ActiveSupport::TestCase
  setup do
    @account = CollavreNotion::NotionAccount.new(token: "tok", notion_uid: "uid")
    # The answer is latched for the life of the process (see #mock_enabled?),
    # and boot already asked. Every case here changes the inputs, so it has to
    # start from unresolved.
    CollavreNotion.mock_latch = nil
  end

  teardown do
    CollavreNotion.mock_latch = nil
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
      assert_equal CollavreNotion.mock_server_base_url, base_url
    end
  end

  test "no credentials in development auto-enables the mock" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil) do
      assert CollavreNotion.mock_enabled?
      assert_equal CollavreNotion.mock_server_base_url, base_url
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

  # NOTION_MOCK_PORT is how a developer gets off a conflicting port. It moves the
  # server; a client default frozen on 4568 would then dial nothing.
  test "NOTION_MOCK_PORT moves the mocked client with the mock server" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil,
           "NOTION_MOCK_PORT" => "4999") do
      assert_equal 4999, CollavreNotion.mock_server_port
      assert_equal "http://localhost:4999/v1", base_url,
        "the port that the mock server binds has to be the port the client dials"
    end
  end

  test "the mock port default is the documented one" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil,
           "NOTION_MOCK_PORT" => nil) do
      assert_equal 4568, CollavreNotion.mock_server_port
      assert_equal "http://localhost:4568/v1", base_url
    end
  end

  # The middleware picks a provider once, at boot. If the API host could still
  # move afterwards, an account minted by one integration would be talking to the
  # other — a real workspace token to localhost, or a fake one to Notion.
  test "a settings change after boot does not move the API host" do
    in_env("development", "NOTION_CLIENT_ID" => nil, "NOTION_MOCK" => nil) do
      assert_equal "http://localhost:4568/v1", base_url, "boot-time answer: no credentials, mock on"

      # What the admin UI does — the same write the middleware could not have seen.
      Collavre::IntegrationSetting.create!(key: "notion_mock", category: "notion_oauth", value: "0")
      Rails.cache.clear

      assert_equal "http://localhost:4568/v1", base_url,
        "requires_restart: the provider registered at boot is still the one holding the tokens"

      CollavreNotion.mock_latch = nil
      assert_equal CollavreNotion::NotionClient::DEFAULT_BASE_URL, base_url,
        "and the new setting is what the next boot resolves"
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
