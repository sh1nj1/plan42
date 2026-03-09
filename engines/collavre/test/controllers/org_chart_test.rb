require "test_helper"

class OrgChartTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @other_user = users(:two)
    @third_user = users(:three)

    # Root creative owned by @owner
    @root_creative = Collavre::Creative.create!(user: @owner, description: "Project Alpha")

    # Child creative under root
    @child_creative = Collavre::Creative.create!(
      user: @owner,
      description: "API Design",
      parent: @root_creative
    )

    # Share root with @other_user (admin permission)
    @share_root = Collavre::CreativeShare.create!(
      creative: @root_creative,
      user: @other_user,
      shared_by: @owner,
      permission: :admin
    )

    # Share child with @third_user (feedback permission)
    @share_child = Collavre::CreativeShare.create!(
      creative: @child_creative,
      user: @third_user,
      shared_by: @owner,
      permission: :feedback
    )

    # Creative owned by @other_user, shared with @owner (read)
    @external_creative = Collavre::Creative.create!(user: @other_user, description: "External Project")
    @share_external = Collavre::CreativeShare.create!(
      creative: @external_creative,
      user: @owner,
      shared_by: @other_user,
      permission: :read
    )

    # Rebuild permission caches (jobs don't auto-run in test)
    [ @root_creative, @child_creative, @external_creative ].each do |c|
      Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(c)
    end
  end

  # --- Org Chart Tab ---

  test "org chart tab displays owned creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, "Project Alpha"
    assert_includes response.body, "API Design"
  end

  test "org chart tab displays shared creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, "External Project"
  end

  test "org chart tab shows shared members" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, @other_user.display_name
    assert_includes response.body, @other_user.email
    assert_includes response.body, @third_user.display_name
  end

  test "org chart tab shows permission badges" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.permissions.admin")
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.permissions.feedback")
  end

  test "org chart tab shows owner badge for owned creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.owner")
  end

  test "org chart tab shows sharer name for shared creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    # External Project was shared by @other_user
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.shared_by_user", user: @other_user.display_name)
  end

  test "org chart shows non-root shared creatives by walking up to root" do
    # @third_user only has share on child_creative (not root)
    sign_in_as(@third_user, password: "password")
    get collavre.user_path(@third_user, tab: "org_chart")

    assert_response :success
    # Should see root creative (walked up from child)
    assert_includes response.body, "Project Alpha"
    assert_includes response.body, "API Design"
  end

  test "org chart shows permission select for admin users" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_select "select.org-chart-permission-select"
  end

  test "org chart shows permission badge (not select) for non-admin users" do
    sign_in_as(@third_user, password: "password")
    get collavre.user_path(@third_user, tab: "org_chart")

    assert_response :success
    assert_select "span.org-chart-permission-badge"
    assert_select "select.org-chart-permission-select", count: 0
  end

  test "org chart shows manage permissions button for admin" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.manage_permissions")
  end

  test "org chart shows no_access shares" do
    no_access_share = Collavre::CreativeShare.create!(
      creative: @root_creative,
      user: @third_user,
      shared_by: @owner,
      permission: :no_access
    )

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.permissions.no_access")
  ensure
    no_access_share&.destroy
  end

  test "org chart empty state for user with no creatives" do
    new_user = User.create!(email: "empty@example.com", password: "password", name: "Empty User")
    sign_in_as(new_user, password: "password")
    get collavre.user_path(new_user, tab: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.empty_state")
  end

  # --- Creative Shares Update (Permission Change) ---

  test "admin can update share permission" do
    sign_in_as(@owner, password: "password")

    patch collavre.creative_creative_share_path(@root_creative, @share_root),
          params: { permission: "write" },
          headers: { "Accept" => "application/json" },
          as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "write", body["permission"]
    assert_equal "write", @share_root.reload.permission
  end

  test "non-admin cannot update share permission" do
    sign_in_as(@third_user, password: "password")

    patch collavre.creative_creative_share_path(@root_creative, @share_root),
          params: { permission: "write" },
          headers: { "Accept" => "application/json" },
          as: :json

    assert_response :forbidden
    assert_equal "admin", @share_root.reload.permission
  end

  # --- Creative Shares Index (Share Modal) ---

  test "admin can load share modal via index" do
    sign_in_as(@owner, password: "password")

    get collavre.creative_creative_shares_path(@root_creative),
        headers: { "Accept" => "text/html" }

    assert_response :success
    assert_includes response.body, "share-creative-modal"
  end

  test "non-admin cannot load share modal" do
    sign_in_as(@third_user, password: "password")

    get collavre.creative_creative_shares_path(@root_creative),
        headers: { "Accept" => "text/html" }

    assert_response :forbidden
  end

  # --- Unshare (Destroy) ---

  test "admin can unshare a user" do
    sign_in_as(@owner, password: "password")

    assert_difference("Collavre::CreativeShare.count", -1) do
      delete collavre.creative_creative_share_path(@child_creative, @share_child)
    end
  end

  test "non-admin cannot unshare a user" do
    sign_in_as(@third_user, password: "password")

    assert_no_difference("Collavre::CreativeShare.count") do
      delete collavre.creative_creative_share_path(@root_creative, @share_root)
    end
  end

  # --- Pending Invitations ---

  test "org chart shows pending invitations for admin" do
    invitation = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "newbie@example.com",
      permission: :write
    )

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    assert_includes response.body, "newbie@example.com"
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.pending_status")
  ensure
    invitation&.destroy
  end

  test "org chart does not show expired invitations" do
    expired = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "expired@example.com",
      permission: :read,
      expires_at: 1.day.ago
    )

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "org_chart")

    assert_response :success
    refute_includes response.body, "expired@example.com"
  ensure
    expired&.destroy
  end

  test "admin can update invitation permission" do
    invitation = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "invited@example.com",
      permission: :read
    )

    sign_in_as(@owner, password: "password")
    patch collavre.creative_invitation_path(@root_creative, invitation),
          params: { permission: "write" },
          headers: { "Accept" => "application/json" },
          as: :json

    assert_response :success
    assert_equal "write", invitation.reload.permission
  ensure
    invitation&.destroy
  end

  test "non-admin cannot update invitation permission" do
    invitation = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "invited@example.com",
      permission: :read
    )

    sign_in_as(@third_user, password: "password")
    patch collavre.creative_invitation_path(@root_creative, invitation),
          params: { permission: "admin" },
          headers: { "Accept" => "application/json" },
          as: :json

    assert_response :forbidden
    assert_equal "read", invitation.reload.permission
  ensure
    invitation&.destroy
  end

  test "admin can cancel invitation" do
    invitation = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "cancel-me@example.com",
      permission: :write
    )

    sign_in_as(@owner, password: "password")
    assert_difference("Collavre::Invitation.count", -1) do
      delete collavre.creative_invitation_path(@root_creative, invitation)
    end
  end

  test "non-admin cannot cancel invitation" do
    invitation = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "protected@example.com",
      permission: :read
    )

    sign_in_as(@third_user, password: "password")
    assert_no_difference("Collavre::Invitation.count") do
      delete collavre.creative_invitation_path(@root_creative, invitation)
    end
  ensure
    invitation&.destroy
  end

  test "share modal shows pending invitations" do
    invitation = Collavre::Invitation.create!(
      inviter: @owner,
      creative: @root_creative,
      email: "modal-test@example.com",
      permission: :feedback
    )

    sign_in_as(@owner, password: "password")
    get collavre.creative_creative_shares_path(@root_creative),
        headers: { "Accept" => "text/html" }

    assert_response :success
    assert_includes response.body, "modal-test@example.com"
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.pending_status")
  ensure
    invitation&.destroy
  end
end
