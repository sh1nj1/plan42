require "test_helper"

class NotionPageLinkTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123",
      name: "Test User"
    )

    @account = NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      token: "test-token"
    )

    @creative = Creative.create!(
      user: @user,
      description: "Test Creative"
    )
  end

  test "should belong to creative and notion_account" do
    link = NotionPageLink.new(
      creative: @creative,
      notion_account: @account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )
    assert link.valid?
  end

  test "should require page_id and page_title" do
    link = NotionPageLink.new(
      creative: @creative,
      notion_account: @account
    )
    assert_not link.valid?
    assert_includes link.errors[:page_id], "can't be blank"
    assert_includes link.errors[:page_title], "can't be blank"
  end

  test "should validate uniqueness of page_id" do
    NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "unique-page-id",
      page_title: "First Page"
    )

    duplicate = NotionPageLink.new(
      creative: @creative,
      notion_account: @account,
      page_id: "unique-page-id",
      page_title: "Second Page"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:page_id], "has already been taken"
  end

  test "mark_synced! should update last_synced_at" do
    link = NotionPageLink.create!(
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
    synced_link = NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "synced-page-id",
      page_title: "Synced Page",
      last_synced_at: 1.hour.ago
    )

    unsynced_link = NotionPageLink.create!(
      creative: @creative,
      notion_account: @account,
      page_id: "unsynced-page-id",
      page_title: "Unsynced Page"
    )

    assert_includes NotionPageLink.synced, synced_link
    assert_not_includes NotionPageLink.synced, unsynced_link

    assert_equal synced_link, NotionPageLink.recent.first
  end
end
