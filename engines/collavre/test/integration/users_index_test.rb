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
    assert_includes response.body, I18n.l(user.created_at, format: :collavre_users_joined_at)
    assert_includes response.body, user.created_at.year.to_s
  end

  test "paginates users by joined date with newest users first" do
    oldest_joined_at = 30.days.ago.change(usec: 0)
    users = 21.times.map do |index|
      User.create!(
        email: "page-user-#{index}@example.com",
        password: TEST_PASSWORD,
        name: "Page User #{index}",
        created_at: oldest_joined_at + [ index, 19 ].min.days
      )
    end

    get users_path

    assert_response :success
    assert_includes response.body, users.last.email
    assert_not_includes response.body, users.first.email
    assert_equal users[-2].created_at, users.last.created_at
    assert_operator users.last.id, :>, users[-2].id
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
