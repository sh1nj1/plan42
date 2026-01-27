require "test_helper"

class CreativesControllerPublicExportTest < ActionDispatch::IntegrationTest
  test "publicly shared creative can be exported as markdown without login" do
    creative = creatives(:root_parent)
    # Create public share (user: nil)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: nil, permission: :read)
    end

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :success
    assert_equal "text/markdown", response.media_type
    expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    assert_equal expected_markdown, response.body
  end
end
