require "test_helper"

class CommentsControllerVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "last read marker is cleared when user has read all VISIBLE comments" do
    # 1. User (@user) and Other User (two)
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    # 2. Other user posts a PUBLIC comment (X)
    public_comment = @creative.comments.create!(content: "Public Comment", user: other_user, private: false)

    # 3. Simulate User reading up to X
    # We need to manually create/update the read pointer
    pointer = CommentReadPointer.find_or_initialize_by(user: @user, creative: @creative.effective_origin)
    pointer.update!(last_read_comment_id: public_comment.id)

    # 4. Other user posts a PRIVATE comment (Y) - Invisible to @user
    # Note: Variable unused, but record creation is vital for test scenario
    @creative.comments.create!(content: "Private Comment", user: other_user, private: true)

    # 5. User requests index
    get creative_comments_path(@creative)
    assert_response :success

    # 6. Expectation:
    # Since @user has read everything they can see (up to X), the marker should BE GONE.
    # If the marker logic was broken (using global max Y), it would think X is not the end, and show the marker on X.

    # Check that public_comment does NOT have the 'last-read' class
    assert_select "#comment_#{public_comment.id}.last-read", false, "Should not show unread marker since user read all visible comments"

    # Counter-test: If we revert the fix, this assertion would fail (it would have .last-read)
  end
end
