require_relative "../test_helper"

class NotionClientTreeTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @client = CollavreNotion::NotionClient.new(create_notion_account(@user))
  end

  test "moves a page with the supported version and typed parent" do
    request = stub_request(:post, %r{/v1/pages/page/move}).with(
      headers: { "Notion-Version" => "2025-09-03" },
      body: { parent: { type: "page_id", page_id: "parent" } }.to_json
    ).to_return(status: 200, body: { id: "page" }.to_json, headers: { "Content-Type" => "application/json" })
    assert_equal "page", @client.move_page("page", parent_id: "parent")["id"]
    assert_requested request
  end

  test "archives only the selected page" do
    request = stub_request(:patch, %r{/v1/pages/page}).with(body: { archived: true }.to_json)
      .to_return(status: 200, body: { id: "page", archived: true }.to_json, headers: { "Content-Type" => "application/json" })
    assert @client.archive_page("page")["archived"]
    assert_requested request
  end

  test "not found errors still propagate for page updates" do
    stub_request(:patch, %r{/v1/pages/page$}).to_return(status: 404, body: "{}")
    service = CollavreNotion::NotionService.new(user: @user)
    assert_raises(CollavreNotion::NotionNotFoundError) { service.update_page("page") }
  end

  test "rate limited moves raise the retryable error" do
    stub_request(:post, %r{/v1/pages/page/move}).to_return(status: 429, body: "{}")
    assert_raises(CollavreNotion::NotionRateLimitError) { @client.move_page("page", parent_id: "parent") }
  end
end
