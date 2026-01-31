require_relative "../../test_helper"

class Creatives::NotionIntegrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @user = create_user(email: "notion-controller-test@example.com", name: "Notion Controller Test User")

    @creative = create_creative(@user)

    sign_in_as(@user)
  end

  test "should show integration status when not connected" do
    get notion_engine.creative_notion_integration_path(@creative)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_not response_data["connected"]
    assert_nil response_data["account"]
    assert_empty response_data["linked_pages"]
  end

  test "should show integration status when connected" do
    account = CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )

    CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: account,
      page_id: "test-page-id",
      page_title: "Test Page",
      page_url: "https://notion.so/test-page"
    )

    get notion_engine.creative_notion_integration_path(@creative)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["connected"]
    assert_equal "Test Workspace", response_data["account"]["workspace_name"]
    assert_equal 1, response_data["linked_pages"].length
    assert_equal "test-page-id", response_data["linked_pages"][0]["page_id"]
  end

  test "should require authentication for updates" do
    patch notion_engine.creative_notion_integration_path(@creative),
          params: { action: "export" },
          as: :json

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "not_connected", response_data["error"]
  end

  test "should handle export action with valid account" do
    CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )

    # Use test adapter for this test to verify job enqueueing
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    begin
      # Mock the job enqueue since we don't want to actually call Notion API in tests
      assert_enqueued_with(job: CollavreNotion::NotionExportJob) do
        patch notion_engine.creative_notion_integration_path(@creative),
              params: { action: "export", parent_page_id: "parent-id" },
              as: :json
      end
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["success"]
    assert_equal "Export started", response_data["message"]
  end

  test "should require admin permission for show and update" do
    other_user = create_user(email: "other-notion@example.com", name: "Other Notion User")
    other_creative = create_creative(other_user)

    get notion_engine.creative_notion_integration_path(other_creative)
    assert_response :forbidden

    patch notion_engine.creative_notion_integration_path(other_creative),
          params: { action: "export" },
          as: :json
    assert_response :forbidden
  end

  test "should delete page links" do
    account = CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )

    CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )

    assert_difference "CollavreNotion::NotionPageLink.count", -1 do
      delete notion_engine.creative_notion_integration_path(@creative),
             params: { page_id: "test-page-id" },
             as: :json
    end

    assert_response :success
  end
end
