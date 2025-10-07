require "test_helper"

class CreativesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one), password: "password")
  end

  test "unconvert moves creative tree into parent comment" do
    creative = creatives(:unconvert_target)
    parent = creative.parent
    grandchild = creatives(:unconvert_grandchild)
    expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ])

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

  test "unconvert without children returns error" do
    creative = creatives(:childless_creative)
    post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("creatives.index.unconvert_no_children"), body["error"]
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
    expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
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
    expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    assert_equal expected_markdown, response.body
  end
end
