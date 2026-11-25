require "test_helper"

class CommentResponseTest < ActiveSupport::TestCase
  test "approval failures retain their message and HTTP status including unknown statuses" do
    controller = Collavre::CommentsController.new
    {
      invalid_action_format: [ "approve_invalid_format", :unprocessable_entity ],
      missing_action: [ "approve_missing_action", :unprocessable_entity ],
      missing_approver: [ "approve_missing_approver", :unprocessable_entity ],
      admin_required: [ "approve_admin_required", :forbidden ],
      not_allowed: [ "approve_not_allowed", :forbidden ],
      unknown: [ "approve_not_allowed", :forbidden ]
    }.each do |status, (key, http_status)|
      rendered = nil
      controller.stub(:render, ->(**options) { rendered = options }) do
        controller.send(:render_approval_status_error, status)
      end
      assert_equal({ error: I18n.t("collavre.comments.#{key}") }, rendered[:json])
      assert_equal http_status, rendered[:status]
    end
  end

  test "comment responses reload persisted content and preload rendering associations" do
    comment = Collavre::Comment.create!(creative: creatives(:tshirt), user: users(:one), content: "Persisted response")
    comment.content = "Unsaved response"
    controller = Collavre::CommentsController.new
    controller.instance_variable_set(:@comment, comment)
    controller.params = ActionController::Parameters.new(comment: { topic_id: "topic-context" })

    [ :ok, :created ].each do |status|
      rendered = nil
      controller.stub(:render, ->(**options) { rendered = options }) do
        controller.send(:render_comment_response, status: status)
      end
      rendered_comment = rendered[:locals][:comment]
      assert_equal "Persisted response", rendered_comment.content
      assert_equal "topic-context", rendered[:locals][:current_topic_id]
      assert_equal "collavre/comments/comment", rendered[:partial]
      assert_equal status, rendered[:status]
      [ :images_attachments, :comment_reactions, :comment_versions, :selected_version ].each do |association|
        assert rendered_comment.association(association).loaded?, "#{association} should be preloaded"
      end
    end
  end
end
