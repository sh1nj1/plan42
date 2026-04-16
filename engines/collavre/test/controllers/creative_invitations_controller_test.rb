require "test_helper"

class CreativeInvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @other_user = users(:two)
    @creative = creatives(:tshirt)
    @invitation = Collavre::Invitation.create!(
      email: "invitee@example.com",
      inviter: @owner,
      creative: @creative,
      permission: :read
    )
  end

  test "non-admin user gets 404 (not 403) when updating an invitation" do
    sign_in_as(@other_user, password: "password")

    patch collavre.creative_invitation_path(@creative, @invitation),
          params: { permission: :write },
          as: :json

    assert_response :not_found
    assert_equal "read", @invitation.reload.permission
  end

  test "non-admin user gets 404 (not 403) when destroying an invitation" do
    sign_in_as(@other_user, password: "password")

    assert_no_difference("Collavre::Invitation.count") do
      delete collavre.creative_invitation_path(@creative, @invitation), as: :json
    end

    assert_response :not_found
  end

  test "admin can update invitation permission" do
    sign_in_as(@owner, password: "password")

    patch collavre.creative_invitation_path(@creative, @invitation),
          params: { permission: :write },
          as: :json

    assert_response :ok
    assert_equal "write", @invitation.reload.permission
  end

  test "admin can destroy invitation" do
    sign_in_as(@owner, password: "password")

    assert_difference("Collavre::Invitation.count", -1) do
      delete collavre.creative_invitation_path(@creative, @invitation), as: :json
    end

    assert_response :no_content
  end
end
