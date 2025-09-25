require "test_helper"

class UsersIndexTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = User.create!(email: "viewer@example.com", password: "pw", name: "Viewer", system_admin: true)
    sign_in_as(@viewer)
  end

  test "displays user email" do
    user = User.create!(email: "test@example.com", password: "pw", name: "Test User")

    get users_path

    assert_response :success
    assert_includes response.body, user.email
  end

  test "shows last login timestamp and inactive avatar count" do
    initial_inactive = User.left_outer_joins(:sessions).where(sessions: { id: nil }).count

    active = User.create!(email: "active@example.com", password: "pw", name: "Active User")
    session = active.sessions.create!(ip_address: "127.0.0.1", user_agent: "test")
    User.create!(email: "inactive@example.com", password: "pw", name: "Inactive User")

    get users_path

    assert_response :success
    assert_includes response.body, I18n.l(session.created_at, format: :short)

    inactive_count = response.body.scan("comment-presence-avatar inactive").size
    assert_equal initial_inactive + 1, inactive_count
  end
end
