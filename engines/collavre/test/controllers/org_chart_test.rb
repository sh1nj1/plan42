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
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_includes response.body, "Project Alpha"
    assert_includes response.body, "API Design"
  end

  test "org chart tab displays shared creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_includes response.body, "External Project"
  end

  test "org chart tab shows shared members" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_includes response.body, @other_user.display_name
    assert_includes response.body, @other_user.email
    assert_includes response.body, @third_user.display_name
  end

  test "org chart tab shows permission badges" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.permissions.admin")
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.permissions.feedback")
  end

  test "org chart tab shows owner badge for owned creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.owner")
  end

  test "org chart tab shows sharer name for shared creatives" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    # External Project was shared by @other_user
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.shared_by_user", user: @other_user.display_name)
  end

  test "org chart shows non-root shared creatives by walking up to root" do
    # @third_user only has share on child_creative (not root)
    sign_in_as(@third_user, password: "password")
    get collavre.user_path(@third_user, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    # Should see root creative (walked up from child)
    assert_includes response.body, "Project Alpha"
    assert_includes response.body, "API Design"
  end

  test "org chart shows permission select for admin users" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_select "select.org-chart-permission-select"
  end

  test "org chart shows permission badge (not select) for non-admin users" do
    sign_in_as(@third_user, password: "password")
    get collavre.user_path(@third_user, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_select "span.org-chart-permission-badge"
    assert_select "select.org-chart-permission-select", count: 0
  end

  test "org chart shows manage permissions button for admin" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

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
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.contacts.org_chart.permissions.no_access")
  ensure
    no_access_share&.destroy
  end

  test "org chart empty state for user with no creatives" do
    new_user = User.create!(email: "empty@example.com", password: "password", name: "Empty User")
    sign_in_as(new_user, password: "password")
    get collavre.user_path(new_user, tab: "contacts", contacts_view: "org_chart")

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
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

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
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")

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

  test "intermediate depth creatives render in tree even without shares" do
    sign_in_as(@owner, password: "password")

    # Create A > B > C structure
    grandchild = Collavre::Creative.create!(
      user: @owner,
      description: "Deep Task",
      parent: @child_creative
    )

    # Share only on grandchild (C), nothing on child (B)
    Collavre::CreativeShare.create!(
      creative: grandchild,
      user: @third_user,
      shared_by: @owner,
      permission: :read
    )
    Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(grandchild)

    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")
    assert_response :success

    # All three levels should be rendered
    assert_includes response.body, "Project Alpha"
    assert_includes response.body, "API Design"
    assert_includes response.body, "Deep Task"
  ensure
    grandchild&.destroy
  end

  # --- Creatives without shares should not appear ---

  test "creatives without any shares are not displayed" do
    # Create a creative with NO shares
    no_share_creative = Collavre::Creative.create!(
      user: @owner,
      description: "Empty Project No Shares"
    )

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")
    assert_response :success

    assert_not_includes response.body, "Empty Project No Shares"
  ensure
    no_share_creative&.destroy
  end

  test "child creative without shares is not displayed even if parent has shares" do
    # @root_creative has shares, but add a child with NO shares
    lonely_child = Collavre::Creative.create!(
      user: @owner,
      description: "Lonely Child No Shares",
      parent: @root_creative
    )

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")
    assert_response :success

    # Root should appear (has shares), but lonely child should not
    assert_includes response.body, "Project Alpha"
    assert_not_includes response.body, "Lonely Child No Shares"
  ensure
    lonely_child&.destroy
  end

  test "only creatives on share path are displayed in tree" do
    # A > B > C structure where A and C have shares but B does not
    mid = Collavre::Creative.create!(
      user: @owner,
      description: "Middle No Direct Share",
      parent: @root_creative
    )
    leaf = Collavre::Creative.create!(
      user: @owner,
      description: "Leaf With Share",
      parent: mid
    )
    Collavre::CreativeShare.create!(
      creative: leaf,
      user: @third_user,
      shared_by: @owner,
      permission: :read
    )
    Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(leaf)

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")
    assert_response :success

    # Root (has shares) and leaf (has shares) should appear
    # Middle should also appear as path connector
    assert_includes response.body, "Project Alpha"
    assert_includes response.body, "Middle No Direct Share"
    assert_includes response.body, "Leaf With Share"
  ensure
    leaf&.destroy
    mid&.destroy
  end

  test "linked creative shows origin shares" do
    # Create origin creative with shares
    origin = Collavre::Creative.create!(
      user: @owner,
      description: "Origin Creative"
    )
    Collavre::CreativeShare.create!(
      creative: origin,
      user: @other_user,
      shared_by: @owner,
      permission: :write
    )
    Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(origin)

    # Create linked creative (origin_id set)
    linked = Collavre::Creative.create!(
      user: @owner,
      description: "Linked Creative",
      origin_id: origin.id
    )

    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts", contacts_view: "org_chart")
    assert_response :success

    # Linked creative should appear with origin's description (via effective_description)
    assert_select "a[href='#{collavre.creative_path(linked)}']", text: /Origin Creative/
    # Origin shares user should be visible under the linked creative
    assert_includes response.body, @other_user.display_name
    # Linked creative should show Owner badge (from origin's user_id)
    # and Permissions button pointing to origin's shares
    assert_select "a[href='#{collavre.creative_path(linked)}']" do |links|
      # Find the details group containing the linked creative
      details = links.first.ancestors.find { |n| n.name == "details" }
      assert details, "Expected <details> wrapper for linked creative"
      assert_match(/Owner/, details.text) if details
      assert_match(/Permissions/, details.text) if details
    end
  ensure
    linked&.destroy
    origin&.destroy
  end

  test "list view shows contacts table by default" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts")
    assert_response :success
    assert_select ".contact-management"
    assert_select ".contacts-table"
    assert_includes response.body, @other_user.display_name
  end

  test "view switcher links are present" do
    sign_in_as(@owner, password: "password")
    get collavre.user_path(@owner, tab: "contacts")
    assert_response :success
    assert_select ".contacts-view-switcher"
    assert_select ".contacts-view-switcher a", minimum: 2
  end
end
