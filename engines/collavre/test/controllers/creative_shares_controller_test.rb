require "test_helper"

class CreativeSharesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @creative = creatives(:tshirt)
    @target_user = users(:three)
  end

  test "creating a share adds the target to contacts" do
    sign_in_as(@owner, password: "password")

    assert_difference([ "CreativeShare.count", "Contact.count" ], 1) do
      post collavre.creative_creative_shares_path(@creative), params: { user_email: @target_user.email, permission: :read }
    end

    assert Contact.exists?(user: @owner, contact_user: @target_user)
  end
end
