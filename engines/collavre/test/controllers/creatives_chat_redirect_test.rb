require "test_helper"

class CreativesChatRedirectTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one), password: "password")
    @creative = Creative.create!(user: users(:one), description: "Onboarding chat")
  end

  test "onboarding chat flag survives the show redirect" do
    get creative_path(@creative, open_comments: true)
    assert_redirected_to creatives_path(id: @creative.id, open_comments: true)
    follow_redirect!
    assert_response :success
    assert_select '[data-controller~="comments--popup"]'
  end

  test "chat flag and comment deep link survive together" do
    get creative_path(@creative, open_comments: true, comment_id: 123)
    assert_redirected_to creatives_path(id: @creative.id, open_comments: true, comment_id: 123)
  end

  test "ordinary creative navigation does not request chat" do
    get creative_path(@creative)
    assert_redirected_to creatives_path(id: @creative.id)
  end
end
