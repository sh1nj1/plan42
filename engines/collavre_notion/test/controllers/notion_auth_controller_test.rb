require_relative "../test_helper"

module CollavreNotion
  class NotionAuthControllerTest < ActionDispatch::IntegrationTest
    # The fixed identity the development mock hands to every browser, whether it
    # arrives through Strategies::NotionMock or — when GitHub's mock has turned
    # OmniAuth's global test_mode on — through mock_auth[:notion]. This drives it
    # the second way, which is the one a test can stand up.
    MOCK_UID = "notion-dev-user-001".freeze

    setup do
      @alice = create_user(email: "notion-alice@example.com", name: "Alice")
      @bob   = create_user(email: "notion-bob@example.com", name: "Bob")

      @previous_test_mode = OmniAuth.config.test_mode
      @previous_mock_auth = OmniAuth.config.mock_auth[:notion]
      OmniAuth.config.test_mode = true
    end

    teardown do
      OmniAuth.config.test_mode = @previous_test_mode
      OmniAuth.config.mock_auth[:notion] = @previous_mock_auth
    end

    test "two developers connecting through the mock get one account each" do
      # notion_uid is uniquely indexed and notion_accounts holds one row per
      # user, so the shared mock uid used to make Bob's connect find Alice's row
      # — `user` is only assigned on create — take her token over, and leave his
      # own integration reading "not connected".
      CollavreNotion.stub(:mock_enabled?, true) do
        connect_as(@alice)
        connect_as(@bob)
      end

      alice_account = NotionAccount.find_by(user: @alice)
      bob_account   = NotionAccount.find_by(user: @bob)

      assert alice_account, "Alice keeps the account she connected"
      assert bob_account, "Bob gets his own instead of updating Alice's"
      assert_not_equal alice_account.notion_uid, bob_account.notion_uid
    end

    test "a real connection stores the provider's uid untouched" do
      # Real Notion returns a per-installation bot id, which identifies the
      # connection on its own — scoping it would break re-authorisation.
      CollavreNotion.stub(:mock_enabled?, false) do
        connect_as(@alice, uid: "8f1e0a0c-real-bot-id")
      end

      assert_equal "8f1e0a0c-real-bot-id", NotionAccount.find_by(user: @alice)&.notion_uid
    end

    test "a mock callback with no session asks for sign-in instead of writing" do
      CollavreNotion.stub(:mock_enabled?, true) do
        OmniAuth.config.mock_auth[:notion] = auth_hash(MOCK_UID)
        get "/auth/notion"
        follow_redirect!
      end

      assert_redirected_to collavre.new_session_path
      assert_equal 0, NotionAccount.count
    end

    private

    def connect_as(user, uid: MOCK_UID)
      sign_out
      sign_in_as(user)

      OmniAuth.config.mock_auth[:notion] = auth_hash(uid)
      get "/auth/notion"
      follow_redirect!
      assert_redirected_to collavre.creatives_path
    end

    def auth_hash(uid)
      OmniAuth::AuthHash.new(
        provider: "notion",
        uid: uid,
        info: { name: "Dev Workspace", workspace_name: "Dev Workspace" },
        credentials: { token: "fake-notion-dev-token" }
      )
    end
  end
end
