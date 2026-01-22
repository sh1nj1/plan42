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
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end

    get export_markdown_creatives_path, headers: { "ACCEPT" => "text/markdown" }

    assert_response :success
    expected_markdown = nil
    Current.set(user: users(:two)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    end
    assert_equal expected_markdown, response.body
  end

  # === HTTP Caching Tests ===

  test "show JSON ETag varies per user" do
    creative = creatives(:root_parent)

    # First user request
    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_one_etag = response.headers["ETag"]

    # Second user request
    sign_out
    sign_in_as(users(:two), password: "password")
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_two_etag = response.headers["ETag"]

    assert_not_equal user_one_etag, user_two_etag, "ETag should vary per user"
  end

  test "show JSON ETag differs for anonymous vs authenticated" do
    creative = creatives(:root_parent)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: nil, permission: :read)
    end

    # Authenticated request
    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    auth_etag = response.headers["ETag"]

    # Anonymous request
    sign_out
    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    anon_etag = response.headers["ETag"]

    assert_not_equal auth_etag, anon_etag, "ETag should differ between authenticated and anonymous users"
  end

  test "show JSON ETag changes when linked creative origin updates" do
    parent = creatives(:root_parent)
    child = creatives(:unconvert_target)
    # Create a linked creative pointing to child
    linked = Creative.create!(user: users(:one), parent: parent, origin: child)

    get creative_path(linked), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    original_etag = response.headers["ETag"]

    # Update the origin creative
    child.touch

    get creative_path(linked), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    updated_etag = response.headers["ETag"]

    assert_not_equal original_etag, updated_etag, "ETag should change when linked creative's origin updates"
  end

  test "show JSON user-private prompt_for does not leak to other users" do
    creative = creatives(:root_parent)
    # Create a private prompt for user one (prompt_for looks for "> " prefix)
    creative.comments.create!(user: users(:one), content: "> secret instructions for user one", private: true)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_one_data = JSON.parse(response.body)
    user_one_prompt = user_one_data["prompt"]

    # User one should see their own prompt
    assert_equal "secret instructions for user one", user_one_prompt,
      "User should see their own private prompt"

    # Grant read access to user two
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end
    sign_out
    sign_in_as(users(:two), password: "password")

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_two_data = JSON.parse(response.body)
    user_two_prompt = user_two_data["prompt"]

    # User two should NOT see user one's private prompt
    assert_nil user_two_prompt, "Private prompt should not leak to other users"
  end

  test "show JSON ETag changes when prompt comment is added" do
    creative = creatives(:root_parent)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    original_etag = response.headers["ETag"]

    # Add a prompt comment
    creative.comments.create!(user: users(:one), content: "> new prompt", private: true)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    updated_etag = response.headers["ETag"]

    assert_not_equal original_etag, updated_etag,
      "ETag should change when prompt comment is added"
  end

  test "show JSON ETag changes when child is added" do
    creative = creatives(:root_parent)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    original_etag = response.headers["ETag"]

    # Add a child
    Creative.create!(user: users(:one), parent: creative, description: "New Child")

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    updated_etag = response.headers["ETag"]
    updated_data = JSON.parse(response.body)

    assert_not_equal original_etag, updated_etag,
      "ETag should change when child is added"
    assert updated_data["has_children"], "has_children should be true after adding child"
  end

  test "children endpoint sets private no-store headers" do
    creative = creatives(:root_parent)

    get children_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    cache_control = response.headers["Cache-Control"]
    # no-store is stronger than no-cache - it prevents all caching
    assert_includes cache_control, "private", "Children endpoint should set private to prevent proxy caching"
    assert_includes cache_control, "no-store", "Children endpoint should set no-store to prevent browser caching"
  end

  test "children endpoint returns new children in response" do
    creative = creatives(:root_parent)

    # First request
    get children_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    first_data = JSON.parse(response.body)
    first_child_ids = first_data["creatives"].map { |c| c["id"] }

    # Add a new child
    new_child = Creative.create!(user: users(:one), parent: creative, description: "Brand New Child")

    # Second request - should see the new child
    get children_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    second_data = JSON.parse(response.body)
    second_child_ids = second_data["creatives"].map { |c| c["id"] }

    assert_includes second_child_ids, new_child.id,
      "New child should appear in response"
      "New child should not have been in first response"
  end

  test "index allows public access by default" do
    sign_out
    get creatives_path
    assert_response :success
  end

  test "index requires login when system setting enabled" do
    SystemSetting.create!(key: "creatives_login_required", value: "true")
    sign_out

    get creatives_path
    assert_redirected_to new_session_path
  end
end
