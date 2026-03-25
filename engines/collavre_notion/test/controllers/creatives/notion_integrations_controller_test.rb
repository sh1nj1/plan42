require_relative "../../test_helper"

module CollavreNotion
  module Creatives
    class NotionIntegrationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = create_user(email: "notion-int@example.com", name: "Notion Integration User")
        @creative = create_creative(@user)
        @account = create_notion_account(@user)
      end

      # --- Show ---

      test "show returns connected status with available pages" do
        sign_in_as(@user)

        pages = [
          mock_notion_page(id: "page-001", title: "Project Notes"),
          mock_notion_page(id: "page-002", title: "Meeting Notes")
        ]
        stub_notion_search(pages)

        get "/notion/creatives/#{@creative.id}/notion_integration",
            headers: { "Accept" => "application/json" }

        assert_response :success
        data = JSON.parse(response.body)
        assert data["connected"]
        assert_equal @account.workspace_name, data["account"]["workspace_name"]
        assert_equal 2, data["available_pages"].size
        assert_equal "Project Notes", data["available_pages"][0]["title"]
      end

      test "show returns not connected when user has no notion account" do
        @account.destroy!
        sign_in_as(@user)

        get "/notion/creatives/#{@creative.id}/notion_integration",
            headers: { "Accept" => "application/json" }

        assert_response :success
        data = JSON.parse(response.body)
        assert_not data["connected"]
        assert_equal [], data["available_pages"]
      end

      test "show returns empty pages when notion api fails" do
        sign_in_as(@user)

        stub_request(:post, %r{/v1/search})
          .to_return(
            status: 401,
            body: { "object" => "error", "status" => 401, "message" => "Unauthorized" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        get "/notion/creatives/#{@creative.id}/notion_integration",
            headers: { "Accept" => "application/json" }

        assert_response :success
        data = JSON.parse(response.body)
        assert data["connected"]
        assert_equal [], data["available_pages"]
      end

      test "show returns linked pages" do
        sign_in_as(@user)

        CollavreNotion::NotionPageLink.create!(
          creative: @creative,
          notion_account: @account,
          page_id: "page-linked-001",
          page_title: "My Linked Page",
          page_url: "https://www.notion.so/linked"
        )

        stub_notion_search([])

        get "/notion/creatives/#{@creative.id}/notion_integration",
            headers: { "Accept" => "application/json" }

        assert_response :success
        data = JSON.parse(response.body)
        assert_equal 1, data["linked_pages"].size
        assert_equal "page-linked-001", data["linked_pages"][0]["page_id"]
        assert_equal "My Linked Page", data["linked_pages"][0]["page_title"]
      end

      # --- Update (Export) ---

      test "update triggers export job" do
        sign_in_as(@user)

        # Stub Notion API calls that the export job may make
        stub_notion_search([ mock_notion_page(id: "page-001", title: "Target") ])
        stub_notion_create_page
        stub_notion_get_blocks(".*")
        stub_notion_append_blocks(".*")

        patch "/notion/creatives/#{@creative.id}/notion_integration",
              params: { action: "export", parent_page_id: "page-001" },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json

        assert_response :success
        data = JSON.parse(response.body)
        assert data["success"]
        assert_equal "Export started", data["message"]
      end

      test "update returns error when not connected" do
        @account.destroy!
        sign_in_as(@user)

        patch "/notion/creatives/#{@creative.id}/notion_integration",
              params: { action: "export", parent_page_id: "page-001" },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json

        assert_response :unprocessable_entity
      end

      # --- Destroy ---

      test "destroy removes all page links" do
        sign_in_as(@user)

        CollavreNotion::NotionPageLink.create!(
          creative: @creative,
          notion_account: @account,
          page_id: "page-to-delete",
          page_title: "Delete Me",
          page_url: "https://www.notion.so/delete"
        )

        delete "/notion/creatives/#{@creative.id}/notion_integration",
               headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
               as: :json

        assert_response :success
        data = JSON.parse(response.body)
        assert data["success"]
        assert_equal [], data["linked_pages"]
      end

      test "destroy removes specific page link" do
        sign_in_as(@user)

        CollavreNotion::NotionPageLink.create!(
          creative: @creative,
          notion_account: @account,
          page_id: "page-keep",
          page_title: "Keep",
          page_url: "https://www.notion.so/keep"
        )
        CollavreNotion::NotionPageLink.create!(
          creative: @creative,
          notion_account: @account,
          page_id: "page-remove",
          page_title: "Remove",
          page_url: "https://www.notion.so/remove"
        )

        delete "/notion/creatives/#{@creative.id}/notion_integration",
               params: { page_id: "page-remove" },
               headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
               as: :json

        assert_response :success
        data = JSON.parse(response.body)
        assert data["success"]
        assert_equal 1, data["linked_pages"].size
        assert_equal "page-keep", data["linked_pages"][0]["page_id"]
      end

      test "destroy returns forbidden for unauthorized user" do
        other_user = create_user(email: "other-notion@example.com", name: "Other")
        sign_in_as(other_user)

        delete "/notion/creatives/#{@creative.id}/notion_integration",
               headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
               as: :json

        assert_response :forbidden
      end
    end
  end
end
