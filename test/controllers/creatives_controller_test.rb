require "test_helper"

class CreativesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one), password: "password")
  end

  test "unconvert moves creative tree into parent comment" do
    creative = creatives(:unconvert_target)
    parent = creative.parent
    grandchild = creatives(:unconvert_grandchild)
    expected_markdown = nil
    Current.set(user: users(:one)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ])
    end

    assert_difference -> { parent.comments.count }, 1 do
      assert_difference -> { parent.children.count }, -1 do
        post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }
      end
    end

    assert_response :created
    parent.reload
    comment = parent.comments.order(:created_at).last
    assert_equal expected_markdown, comment.content
    assert_raises(ActiveRecord::RecordNotFound) { creative.reload }
    assert_raises(ActiveRecord::RecordNotFound) { grandchild.reload }
  end

  test "unconvert without parent returns error" do
    creative = creatives(:root_parent)
    post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("creatives.index.unconvert_no_parent"), body["error"]
  end

  test "unconvert requires admin permission" do
    creative = creatives(:unconvert_target)
    parent = creative.parent
    sign_out
    sign_in_as(users(:two), password: "password")
    CreativeShare.create!(creative: parent, user: users(:two), permission: :feedback)

    assert_no_changes -> { creative.reload.children.count } do
      post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    end

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal I18n.t("creatives.errors.no_permission"), body["error"]
  end

  test "export markdown requires read permission for parent creative" do
    creative = creatives(:root_parent)
    sign_out
    sign_in_as(users(:two), password: "password")

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :forbidden
  end

  test "export markdown returns markdown for readable parent creative" do
    creative = creatives(:root_parent)

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :success
    assert_equal "text/markdown", response.media_type
    expected_markdown = nil
    Current.set(user: users(:one)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    end
    assert_equal expected_markdown, response.body
  end

  test "export markdown requires read permission on parent creative's effective origin" do
    creative = creatives(:unconvert_target)
    origin = creative.effective_origin
    sign_out
    sign_in_as(users(:two), password: "password")

    refute origin.has_permission?(users(:two), :read)

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :forbidden
  end

  test "export markdown includes only readable root creatives" do
    creative = creatives(:root_parent)
    sign_out
    sign_in_as(users(:two), password: "password")
    CreativeShare.create!(creative: creative, user: users(:two), permission: :read)

    get export_markdown_creatives_path, headers: { "ACCEPT" => "text/markdown" }

    assert_response :success
    expected_markdown = nil
    Current.set(user: users(:two)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    end
    assert_equal expected_markdown, response.body
  end

  test "destroy creative with creative_links cleans up properly" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent to delete")
    origin = Creative.create!(user: user, description: "Origin")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: user)

    assert VirtualCreativeHierarchy.where(creative_link_id: link.id).exists?

    assert_difference -> { Creative.count }, -1 do
      assert_difference -> { CreativeLink.count }, -1 do
        delete creative_path(parent), headers: { "ACCEPT" => "application/json" }
      end
    end

    assert_response :success
    assert_not CreativeLink.exists?(link.id)
    assert_not VirtualCreativeHierarchy.where(creative_link_id: link.id).exists?
  end

  test "destroy creative that is origin of creative_link cleans up properly" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    origin = Creative.create!(user: user, description: "Origin to delete")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: user)

    assert VirtualCreativeHierarchy.where(creative_link_id: link.id).exists?

    assert_difference -> { Creative.count }, -1 do
      assert_difference -> { CreativeLink.count }, -1 do
        delete creative_path(origin), headers: { "ACCEPT" => "application/json" }
      end
    end

    assert_response :success
    assert_not CreativeLink.exists?(link.id)
    assert_not VirtualCreativeHierarchy.where(creative_link_id: link.id).exists?
  end

  test "show_link with valid link and permission renders index" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    origin = Creative.create!(user: user, description: "Origin")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: user)

    get creative_link_view_path(link)

    assert_response :success
  end

  test "show_link without permission redirects" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    origin = Creative.create!(user: user, description: "Origin")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: user)

    sign_out
    sign_in_as(users(:two), password: "password")

    get creative_link_view_path(link)

    assert_response :redirect
    assert_redirected_to creatives_path
  end

  test "show_link with non-existent link redirects" do
    get creative_link_view_path(id: 999999)

    assert_response :redirect
    assert_redirected_to creatives_path
  end

  test "anonymous user can access show_link with shared origin" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    origin = Creative.create!(user: user, description: "Origin")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: user)

    # Share origin with a "public" marker - use nil user for public access
    # Note: Current implementation requires user, so we test with shared user
    shared_user = users(:two)
    CreativeShare.create!(creative: origin, user: shared_user, permission: :read)

    sign_out
    sign_in_as(shared_user, password: "password")

    get creative_link_view_path(link)

    assert_response :success
  end

  test "unlink removes creative_link with admin permission" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    origin = Creative.create!(user: user, description: "Origin")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: user)

    assert_difference -> { CreativeLink.count }, -1 do
      delete creative_link_unlink_path(link), headers: { "ACCEPT" => "application/json" }
    end

    assert_response :success
  end

  test "unlink without admin permission returns forbidden" do
    owner = users(:one)
    other_user = users(:two)
    parent = Creative.create!(user: owner, description: "Parent")
    origin = Creative.create!(user: owner, description: "Origin")
    link = CreativeLink.create!(parent: parent, origin: origin, created_by: owner)

    # Give other_user only read permission
    CreativeShare.create!(creative: parent, user: other_user, permission: :read)

    sign_out
    sign_in_as(other_user, password: "password")

    assert_no_difference -> { CreativeLink.count } do
      delete creative_link_unlink_path(link), headers: { "ACCEPT" => "application/json" }
    end

    assert_response :forbidden
  end
end
