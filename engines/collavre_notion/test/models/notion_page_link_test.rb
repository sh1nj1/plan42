require_relative "../test_helper"

class NotionPageLinkTest < ActiveSupport::TestCase
  def setup
    @user = create_user(email: "page-link-test@example.com", name: "Page Link Test User")

    @account = CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      token: "test-token"
    )

    @creative = create_creative(@user)
  end

  test "should belong to creative and notion_account" do
    link = CollavreNotion::NotionPageLink.new(
      creative: @creative,
      notion_account: @account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )
    assert link.valid?
  end

  test "should require page_id and page_title" do
    link = CollavreNotion::NotionPageLink.new(
      creative: @creative,
      notion_account: @account
    )
    assert_not link.valid?
    assert_includes link.errors[:page_id], "can't be blank"
    assert_includes link.errors[:page_title], "can't be blank"
  end

  test "should validate uniqueness of page_id" do
    CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "unique-page-id",
      page_title: "First Page"
    )

    duplicate = CollavreNotion::NotionPageLink.new(
      creative: @creative,
      notion_account: @account,
      page_id: "unique-page-id",
      page_title: "Second Page"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:page_id], "has already been taken"
  end

  test "mark_synced! should update last_synced_at" do
    link = CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )

    assert_nil link.last_synced_at
    link.mark_synced!
    assert_not_nil link.last_synced_at
    assert_in_delta Time.current, link.last_synced_at, 1.second
  end

  test "scopes should work correctly" do
    synced_link = CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "synced-page-id",
      page_title: "Synced Page",
      last_synced_at: 1.hour.ago
    )

    unsynced_link = CollavreNotion::NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "unsynced-page-id",
      page_title: "Unsynced Page"
    )

    assert_includes CollavreNotion::NotionPageLink.synced, synced_link
    assert_not_includes CollavreNotion::NotionPageLink.synced, unsynced_link

    assert_equal synced_link, CollavreNotion::NotionPageLink.recent.first
  end
end
