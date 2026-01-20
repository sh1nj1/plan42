require "test_helper"

class CreativeShareLinkedCreativeTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner@example.com", password: TEST_PASSWORD, name: "Owner")
    @shared_user = User.create!(email: "shared@example.com", password: TEST_PASSWORD, name: "Shared")
    @parent = Creative.create!(user: @owner, description: "Parent")
    @child = Creative.create!(user: @owner, parent: @parent, description: "Child")

    CreativeShare.create!(creative: @parent, user: @shared_user, permission: :read)
    @parent.create_linked_creative_for_user(@shared_user)

    sign_in_as(@owner)
  end

  test "does not create linked creative when parent already shared" do
    post creative_creative_shares_path(@child), params: { creative_id: @child.id, user_email: @shared_user.email, permission: :write }

    assert_redirected_to creatives_path
    assert_nil Creative.find_by(origin_id: @child.id, user_id: @shared_user.id)

    share = CreativeShare.find_by(creative: @child, user: @shared_user)
    assert_not_nil share
    assert_equal "write", share.permission
  end
end
