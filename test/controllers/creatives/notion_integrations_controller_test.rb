require "test_helper"

class Creatives::NotionIntegrationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123",
      name: "Test User"
    )

    @creative = Creative.create!(
      user: @user,
      description: "Test Creative"
    )

    login_as(@user)
  end

  test "should show integration status when not connected" do
    get creative_notion_integration_path(@creative)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_not response_data["connected"]
    assert_nil response_data["account"]
    assert_empty response_data["linked_pages"]
  end

  test "should show integration status when connected" do
    account = NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )

    link = NotionPageLink.create!(
      creative: @creative,
      notion_account: account,
      page_id: "test-page-id",
      page_title: "Test Page",
      page_url: "https://notion.so/test-page"
    )

    get creative_notion_integration_path(@creative)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["connected"]
    assert_equal "Test Workspace", response_data["account"]["workspace_name"]
    assert_equal 1, response_data["linked_pages"].length
    assert_equal "test-page-id", response_data["linked_pages"][0]["page_id"]
  end

  test "should require authentication for updates" do
    patch creative_notion_integration_path(@creative),
          params: { action: "export" },
          as: :json

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "not_connected", response_data["error"]
  end

  test "should handle export action with valid account" do
    account = NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )

    # Mock the job enqueue since we don't want to actually call Notion API in tests
    assert_enqueued_with(job: NotionExportJob) do
      patch creative_notion_integration_path(@creative),
            params: { action: "export", parent_page_id: "parent-id" },
            as: :json
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["success"]
    assert_equal "Export started", response_data["message"]
  end

  test "should require admin permission for show and update" do
    other_user = User.create!(
      email: "other@example.com",
      password: "password123",
      name: "Other User"
    )
    other_creative = Creative.create!(
      user: other_user,
      description: "Other Creative"
    )

    get creative_notion_integration_path(other_creative)
    assert_response :forbidden

    patch creative_notion_integration_path(other_creative),
          params: { action: "export" },
          as: :json
    assert_response :forbidden
  end

  test "should delete page links" do
    account = NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )

    link = NotionPageLink.create!(
      creative: @creative,
      notion_account: account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )

    assert_difference "NotionPageLink.count", -1 do
      delete creative_notion_integration_path(@creative),
             params: { page_id: "test-page-id" },
             as: :json
    end

    assert_response :success
  end

  private

  def login_as(user)
    session = user.sessions.create!
    cookies.signed[:session_token] = session.id
  end
end
