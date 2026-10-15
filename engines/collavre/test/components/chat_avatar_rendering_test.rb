require "test_helper"

class ChatAvatarRenderingTest < ViewComponent::TestCase
  test "default avatar renders an initial without a silhouette and preserves data" do
    user = users(:one)
    user.avatar_url = nil
    render_inline(Collavre::AvatarComponent.new(user: user, size: 20, classes: "avatar comment-avatar", data: { user_id: user.id }))

    assert_no_selector "img"
    assert_selector ".avatar-initial.comment-avatar[data-user-id='#{user.id}']", text: user.display_name[0].upcase
  end

  test "custom and anonymous avatars retain their images" do
    user = users(:one)
    user.avatar_url = "https://example.com/avatar.png"
    render_inline(Collavre::AvatarComponent.new(user: user))
    assert_selector "img[src='https://example.com/avatar.png']"
    assert_no_selector ".avatar-initial"

    render_inline(Collavre::AvatarComponent.new(user: nil))
    assert_selector "img"
    assert_no_selector ".avatar-initial"
  end
end
