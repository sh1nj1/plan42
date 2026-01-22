require "test_helper"

class LinkedCreativeParentTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner@example.com", password: TEST_PASSWORD, name: "Owner")
    @shared_user = User.create!(email: "shared@example.com", password: TEST_PASSWORD, name: "Shared")
    @parent = Creative.create!(user: @owner, description: "Parent")
    @creative = Creative.create!(user: @owner, parent: @parent, description: "Original")
    @new_parent = Creative.create!(user: @shared_user, description: "New Parent")

    CreativeShare.create!(creative: @creative, user: @shared_user, permission: :read)
    @creative.create_linked_creative_for_user(@shared_user)
    @linked = Creative.find_by(origin_id: @creative.id, user_id: @shared_user.id)

    sign_in_as(@shared_user)
  end

  test "updating linked creative parent does not change origin" do
    patch creative_path(@linked), params: { creative: { parent_id: @new_parent.id } }

    assert_redirected_to creative_path(@linked)

    @linked.reload
    @creative.reload

    assert_equal @new_parent.id, @linked.parent_id
    assert_equal @parent.id, @creative.parent_id
  end
end
