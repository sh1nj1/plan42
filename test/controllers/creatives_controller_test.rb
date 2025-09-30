require "test_helper"

class CreativesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one), password: "password")
  end

  test "unconvert moves children into parent comment" do
    creative = creatives(:unconvert_target)
    parent = creative.parent
    children = creative.children.order(:sequence).to_a
    expected_markdown = ApplicationController.helpers.render_creative_tree_markdown(children)

    assert_difference -> { parent.comments.count }, 1 do
      assert_difference -> { creative.children.count }, -children.count do
        post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }
      end
    end

    assert_response :created
    parent.reload
    comment = parent.comments.order(:created_at).last
    assert_equal expected_markdown, comment.content
    creative.reload
    assert_equal 0, creative.children.count
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
end
