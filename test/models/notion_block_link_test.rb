require "test_helper"

class NotionBlockLinkTest < ActiveSupport::TestCase
  def setup
    account = NotionAccount.create!(
      user: users(:one),
      notion_uid: "user-123",
      workspace_id: "workspace-123",
      workspace_name: "Workspace",
      token: "token"
    )

    @page_link = NotionPageLink.create!(
      creative: creatives(:root_parent),
      notion_account: account,
      page_id: "page-123",
      page_title: "Test Page"
    )
  end

  test "requires block id" do
    link = NotionBlockLink.new(notion_page_link: @page_link, creative: creatives(:root_parent))
    assert_not link.valid?
    assert_includes link.errors[:block_id], "can't be blank"
  end

  test "allows multiple blocks for a single creative" do
    NotionBlockLink.create!(notion_page_link: @page_link, creative: creatives(:root_parent), block_id: "block-1")

    additional = NotionBlockLink.new(notion_page_link: @page_link, creative: creatives(:root_parent), block_id: "block-2")
    assert additional.valid?
  end

  test "enforces unique block ids per page link" do
    NotionBlockLink.create!(notion_page_link: @page_link, creative: creatives(:root_parent), block_id: "block-1")

    duplicate = NotionBlockLink.new(notion_page_link: @page_link, creative: creatives(:root_parent), block_id: "block-1")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:block_id], "has already been taken"
  end
end
