require_relative "../test_helper"

class NotionBlockLinkTest < ActiveSupport::TestCase
  def setup
    @user = create_user(email: "block-link-test@example.com", name: "Block Link Test User")

    account = CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "user-123",
      workspace_id: "workspace-123",
      workspace_name: "Workspace",
      token: "token"
    )

    @creative = create_creative(@user)

    @page_link = CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: account,
      page_id: "page-123",
      page_title: "Test Page"
    )
  end

  test "requires block id" do
    link = CollavreNotion::NotionBlockLink.new(notion_page_link: @page_link, creative: @creative)
    assert_not link.valid?
    assert_includes link.errors[:block_id], "can't be blank"
  end

  test "allows multiple blocks for a single creative" do
    CollavreNotion::NotionBlockLink.create!(notion_page_link: @page_link, creative: @creative, block_id: "block-1")

    additional = CollavreNotion::NotionBlockLink.new(notion_page_link: @page_link, creative: @creative, block_id: "block-2")
    assert additional.valid?
  end

  test "enforces unique block ids per page link" do
    CollavreNotion::NotionBlockLink.create!(notion_page_link: @page_link, creative: @creative, block_id: "block-1")

    duplicate = CollavreNotion::NotionBlockLink.new(notion_page_link: @page_link, creative: @creative, block_id: "block-1")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:block_id], "has already been taken"
  end
end
