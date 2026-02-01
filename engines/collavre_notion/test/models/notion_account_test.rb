require_relative "../test_helper"

class NotionAccountTest < ActiveSupport::TestCase
  def setup
    @user = create_user(email: "notion-test@example.com", name: "Notion Test User")
  end

  test "should belong to user" do
    account = CollavreNotion::NotionAccount.new(
      user: @user,
      notion_uid: "test-uid",
      workspace_name: "Test Workspace",
      token: "test-token"
    )
    assert account.valid?
  end

  test "should require notion_uid and token" do
    account = CollavreNotion::NotionAccount.new(user: @user)
    assert_not account.valid?
    assert_includes account.errors[:notion_uid], "can't be blank"
    assert_includes account.errors[:token], "can't be blank"
  end

  test "should validate uniqueness of notion_uid" do
    CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "unique-uid",
      token: "token1"
    )

    other_user = create_user(email: "other@example.com", name: "Other User")
    duplicate = CollavreNotion::NotionAccount.new(
      user: other_user,
      notion_uid: "unique-uid",
      token: "token2"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:notion_uid], "has already been taken"
  end

  test "expired? should work with token_expires_at" do
    account = CollavreNotion::NotionAccount.new(
      user: @user,
      notion_uid: "test-uid",
      token: "test-token",
      token_expires_at: 1.day.ago
    )
    assert account.expired?

    account.token_expires_at = 1.day.from_now
    assert_not account.expired?

    account.token_expires_at = nil
    assert_not account.expired?
  end

  test "should have many notion_page_links" do
    account = CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      token: "test-token"
    )

    creative = create_creative(@user)

    page_link = CollavreNotion::NotionPageLink.create!(
      creative: creative,
      notion_account: account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )

    assert_includes account.notion_page_links, page_link
  end

  test "should destroy dependent notion_page_links" do
    account = CollavreNotion::NotionAccount.create!(
      user: @user,
      notion_uid: "test-uid",
      token: "test-token"
    )

    creative = create_creative(@user)

    CollavreNotion::NotionPageLink.create!(
      creative: creative,
      notion_account: account,
      page_id: "test-page-id",
      page_title: "Test Page"
    )

    assert_difference "CollavreNotion::NotionPageLink.count", -1 do
      account.destroy!
    end
  end
end
