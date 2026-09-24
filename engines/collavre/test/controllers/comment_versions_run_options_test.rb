# frozen_string_literal: true

require "test_helper"

class CommentVersionsRunOptionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    sign_in_as @user, password: "password"
    @comment = @creative.comments.create!(content: "Latest", user: @user)
    @old = @comment.comment_versions.create!(content: "Original", version_number: 1,
      agent_run_options: { "model" => "paperclip/claude_local/sonnet", "reasoning_effort" => "low" })
    @latest = @comment.comment_versions.create!(content: "Latest", version_number: 2,
      agent_run_options: { "model" => "paperclip/claude_local/opus", "reasoning_effort" => "max" })
    @comment.update!(@latest.comment_attributes)
    @url = creative_comment_versions_path(@creative, @comment)
  end

  test "index pairs each version with its own escaped audit chip" do
    @old.update!(agent_run_options: { "model" => "<script>bad</script>", "reasoning_effort" => "low" })
    get @url
    assert_response :success
    versions = response.parsed_body.fetch("versions")
    assert_equal @old.agent_run_options, versions.first.fetch("agent_run_options")
    assert_includes versions.first.fetch("run_options_html"), "&lt;script&gt;"
    refute_includes versions.first.fetch("run_options_html"), "<script>"
    assert_includes versions.last.fetch("run_options_html"), "claude_local/opus · max"
  end

  test "select restores options with content and survives reload" do
    post "#{@url}/#{@old.id}/select"
    assert_response :success
    assert_equal @old.agent_run_options, response.parsed_body.fetch("agent_run_options")
    assert_equal @old.agent_run_options, @comment.reload.agent_run_options
    assert_equal "Original", @comment.content
    get creative_comments_path(@creative)
    assert_select ".agent-run-options-label", text: /claude_local\/sonnet · low/
  end

  test "deleting selected version restores remaining version options" do
    delete "#{@url}/#{@latest.id}"
    assert_response :success
    assert_equal @old.id, @comment.reload.selected_version_id
    assert_equal @old.agent_run_options, @comment.agent_run_options
    assert_equal "Original", @comment.content
  end

  test "deleting unselected version preserves the selected run" do
    delete "#{@url}/#{@old.id}"
    assert_response :success
    assert_equal @latest.agent_run_options, @comment.reload.agent_run_options
    assert_equal @latest.id, @comment.selected_version_id
  end

  test "deleting the final version preserves the visible content and options" do
    @old.destroy!
    delete "#{@url}/#{@latest.id}"
    assert_response :success
    assert_nil @comment.reload.selected_version_id
    assert_equal "Latest", @comment.content
    assert_equal @latest.agent_run_options, @comment.agent_run_options
  end

  test "legacy versions clear the newer audit metadata" do
    @old.update!(agent_run_options: nil)
    get @url
    assert_empty response.parsed_body.fetch("versions").first.fetch("run_options_html").strip
    post "#{@url}/#{@old.id}/select"
    assert_response :success
    assert_nil @comment.reload.agent_run_options
  end
end
