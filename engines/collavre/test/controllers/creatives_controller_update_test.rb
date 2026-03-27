require "test_helper"

class CreativesControllerUpdateTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user, password: "password"

    # Structure:
    # A -> B2 (Linked)
    # B -> B1 (Origin)
    @a = Creative.create!(description: "A", user: @user)
    @b = Creative.create!(description: "B", user: @user)

    @b1_origin = Creative.create!(description: "B1 Origin", user: @user, progress: 0.0, parent: @b)
    @b2_linked = Creative.create!(description: "B2 Linked", user: @user, origin: @b1_origin, parent: @a)
  end

  test "should update linked creative origin without 422 error even if origin_id is in params" do
    # Simulate the request typically sent by a form or frontend
    # It often includes all attributes of the object, including origin_id
    patch creative_url(@b2_linked), params: {
      creative: {
        progress: 0.5,
        description: "Updated Description",
        origin_id: @b1_origin.id # The problematic param
      }
    }

    # Should redirect to the creative (success)
    # If 422, it renders :edit (or returns json error)
    if response.code == "422"
        puts response.body # For debugging
    end
    assert_response :redirect
    assert_redirected_to creative_url(@b2_linked)

    # Verify the update propagated to the origin
    assert_equal 0.5, @b1_origin.reload.progress
  end

  test "update_metadata posts drop trigger warning when enabling without write-permission AI agent" do
    creative = Creative.create!(description: "Documentation", user: @user, data: {})
    feedback_ai = users(:ai_bot)
    CreativeShare.create!(creative: creative, user: feedback_ai, permission: :feedback)

    assert_difference -> { creative.comments.count }, 1 do
      patch update_metadata_creative_url(creative), params: {
        data: {
          trigger: { on_child_enter: true }
        }.to_json
      }
    end

    assert_response :success
    comment = creative.comments.order(:id).last
    assert_nil comment.user_id
    assert_includes comment.content, "⚠️"
    assert_includes comment.content, creative.creative_snippet
    assert_equal "Drop Trigger", comment.topic.name
  end

  test "update_metadata does not post duplicate warning when already enabled" do
    creative = Creative.create!(description: "Documentation", user: @user, data: { "trigger" => { "on_child_enter" => true } })
    feedback_ai = users(:ai_bot)
    CreativeShare.create!(creative: creative, user: feedback_ai, permission: :feedback)

    assert_no_difference -> { creative.comments.count } do
      patch update_metadata_creative_url(creative), params: {
        data: {
          trigger: { on_child_enter: true }
        }.to_json
      }
    end

    assert_response :success
  end
end
