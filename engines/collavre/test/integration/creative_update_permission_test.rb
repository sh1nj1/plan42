require "test_helper"

class CreativeUpdatePermissionTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner-update@example.com", password: TEST_PASSWORD, name: "Owner")
    @feedback_user = User.create!(email: "feedback-update@example.com", password: TEST_PASSWORD, name: "Feedback User")
    @write_user = User.create!(email: "write-update@example.com", password: TEST_PASSWORD, name: "Write User")
    @read_user = User.create!(email: "read-update@example.com", password: TEST_PASSWORD, name: "Read User")

    @creative = Creative.create!(user: @owner, description: "Original Description", sequence: 0)

    CreativeShare.create!(creative: @creative, user: @feedback_user, permission: :feedback)
    CreativeShare.create!(creative: @creative, user: @write_user, permission: :write)
    CreativeShare.create!(creative: @creative, user: @read_user, permission: :read)
  end

  test "owner can update creative" do
    sign_in_as(@owner)
    patch creative_path(@creative), params: { creative: { description: "Updated by owner" } }, as: :json

    assert_response :success
    assert_equal "Updated by owner", @creative.reload.description
  end

  test "write permission user can update creative" do
    sign_in_as(@write_user)
    patch creative_path(@creative), params: { creative: { description: "Updated by writer" } }, as: :json

    assert_response :success
    assert_equal "Updated by writer", @creative.reload.description
  end

  test "feedback permission user cannot update creative" do
    sign_in_as(@feedback_user)
    patch creative_path(@creative), params: { creative: { description: "Updated by feedback" } }, as: :json

    assert_response :forbidden
    assert_equal "Original Description", @creative.reload.description
  end

  test "read permission user cannot update creative" do
    sign_in_as(@read_user)
    patch creative_path(@creative), params: { creative: { description: "Updated by reader" } }, as: :json

    assert_response :forbidden
    assert_equal "Original Description", @creative.reload.description
  end

  test "feedback permission user cannot update progress" do
    sign_in_as(@feedback_user)
    patch creative_path(@creative), params: { creative: { progress: 0.5 } }, as: :json

    assert_response :forbidden
    assert_equal 0.0, @creative.reload.progress.to_f
  end
end
