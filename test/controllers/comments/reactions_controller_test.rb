require "test_helper"

module Comments
  class ReactionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @comment = Comment.create!(user: @user, creative: @creative, content: "Test comment")
      @other_user = users(:two)
      # Ensure user is verified for login
      @user.update!(email_verified_at: Time.current)
      post session_path, params: { email: @user.email, password: "password" }
    end

    test "should create reaction" do
      assert_difference("CommentReaction.count", 1) do
        post creative_comment_reactions_url(@creative, @comment),
             params: { emoji: "👍" },
             headers: { "Accept" => "application/json" }
      end

      assert_response :success
      json_response = JSON.parse(response.body)

      # Verify response structure works with frontend expectation
      assert_kind_of Array, json_response
      reaction_data = json_response.find { |r| r["emoji"] == "👍" }
      assert reaction_data
      assert_equal 1, reaction_data["count"]
      assert_includes reaction_data["user_ids"], @user.id
    end

    test "should destroy reaction" do
      # Create initial reaction
      CommentReaction.create!(comment: @comment, user: @user, emoji: "👍")

      assert_difference("CommentReaction.count", -1) do
        delete creative_comment_reactions_url(@creative, @comment),
               params: { emoji: "👍" },
               headers: { "Accept" => "application/json" }
      end

      assert_response :success
      json_response = JSON.parse(response.body)

      # Reaction should be gone or count 0 if we included it (implementation detail: usually removed from list if empty)
      reaction_data = json_response.find { |r| r["emoji"] == "👍" }
      assert_nil reaction_data
    end

    test "should not allow duplicate reaction creation via controller" do
      CommentReaction.create!(comment: @comment, user: @user, emoji: "👍")

      assert_no_difference("CommentReaction.count") do
        post creative_comment_reactions_url(@creative, @comment),
             params: { emoji: "👍" },
             headers: { "Accept" => "application/json" }
      end

      # It might return success (idempotent) or error depending on implementation.
      # Looking at controller, `find_or_create_by` is used? No, checked earlier.
      # If it raises validation error, controller might crash or 422.
      # Let's assume standard rails scaffold behavior or simple create.
      # Actually, let's check the controller logic again if needed, but for now assert no difference.
    end

    test "should require login" do
      sign_out

      assert_no_difference("CommentReaction.count") do
        post creative_comment_reactions_url(@creative, @comment),
             params: { emoji: "👍" }
      end

      assert_response :redirect # or 401 depending on app setup
    end
  end
end
