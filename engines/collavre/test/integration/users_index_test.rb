require "test_helper"

class UsersIndexTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = User.create!(email: "viewer@example.com", password: TEST_PASSWORD, name: "Viewer", system_admin: true)
    sign_in_as(@viewer)
  end

  test "displays user email" do
    user = User.create!(email: "test@example.com", password: TEST_PASSWORD, name: "Test User")

    get users_path

    assert_response :success
    assert_includes response.body, user.email
  end

  test "uses a horizontally scrollable table and displays joined date" do
    user = User.create!(email: "joined@example.com", password: TEST_PASSWORD, name: "Joined User")

    get users_path

    assert_response :success
    assert_select "div.table-scroll > table.users-table"
    assert_select "th", text: I18n.t("collavre.users.table.joined_at")
    assert_includes response.body, I18n.l(user.created_at, format: :short)
  end

  test "paginates users by joined date with newest users first" do
    users = 21.times.map do |index|
      User.create!(
        email: "page-user-#{index}@example.com",
        password: TEST_PASSWORD,
        name: "Page User #{index}",
        created_at: Time.utc(2040, 1, 1) + index.days
      )
    end

    get users_path

    assert_response :success
    assert_includes response.body, users.last.email
    assert_not_includes response.body, users.first.email
    assert_operator response.body.index(users.last.email), :<, response.body.index(users[-2].email)
    assert_select "nav[aria-label=?]", I18n.t("collavre.users.pagination.label")
    assert_select "a[href=?]", users_path(page: 2), text: I18n.t("collavre.users.pagination.next")

    get users_path(page: 2)

    assert_response :success
    assert_includes response.body, users.first.email
    assert_select "a[href=?]", users_path(page: 1), text: I18n.t("collavre.users.pagination.prev")
  end

  test "shows last login timestamp and inactive avatar count" do
    initial_inactive = User.left_outer_joins(:sessions).where(sessions: { id: nil }).count

    active = User.create!(email: "active@example.com", password: TEST_PASSWORD, name: "Active User")
    session = active.sessions.create!(ip_address: "127.0.0.1", user_agent: "test")
    User.create!(email: "inactive@example.com", password: TEST_PASSWORD, name: "Inactive User")

    get users_path

    assert_response :success
    assert_includes response.body, I18n.l(session.created_at, format: :short)

    inactive_count = response.body.scan("comment-presence-avatar inactive").size
    assert_equal initial_inactive + 1, inactive_count
  end
end
