require "test_helper"

class AvatarComponentTest < ActiveSupport::TestCase
  test "cache_key_for changes when display_name changes" do
    user = users(:one)
    original_key = AvatarComponent.cache_key_for(user, 32)

    # Change display_name (via name attribute)
    user.update!(name: "New Name #{Time.current.to_i}")

    updated_key = AvatarComponent.cache_key_for(user, 32)

    assert_not_equal original_key, updated_key,
      "Cache key should change when user's display_name changes"
  end

  test "cache_key_for changes when user updated_at changes" do
    user = users(:one)
    original_key = AvatarComponent.cache_key_for(user, 32)

    # Touch the user to update updated_at
    user.touch

    updated_key = AvatarComponent.cache_key_for(user, 32)

    assert_not_equal original_key, updated_key,
      "Cache key should change when user's updated_at changes"
  end

  test "cache_key_for includes user cache_key_with_version" do
    user = users(:one)
    cache_key = AvatarComponent.cache_key_for(user, 32)

    # cache_key_with_version format: "users/ID-TIMESTAMP"
    assert_includes cache_key, "users/#{user.id}",
      "Cache key should include user's cache_key_with_version"
  end

  test "cache_key_for varies by size" do
    user = users(:one)
    small_key = AvatarComponent.cache_key_for(user, 32)
    large_key = AvatarComponent.cache_key_for(user, 64)

    assert_not_equal small_key, large_key,
      "Cache key should vary by avatar size"
    assert_includes small_key, "/32"
    assert_includes large_key, "/64"
  end

  test "cache_key_for returns consistent key for anonymous user" do
    key1 = AvatarComponent.cache_key_for(nil, 32)
    key2 = AvatarComponent.cache_key_for(nil, 32)

    assert_equal key1, key2
    assert_equal "avatar/anonymous/32", key1
  end

  test "cache_key_for changes when avatar is attached" do
    user = users(:one)
    original_key = AvatarComponent.cache_key_for(user, 32)

    # Simulate attaching an avatar by setting avatar_url
    # (Direct attachment requires Active Storage setup in tests)
    user.update!(avatar_url: "https://example.com/new-avatar.png")

    updated_key = AvatarComponent.cache_key_for(user, 32)

    assert_not_equal original_key, updated_key,
      "Cache key should change when avatar_url changes"
  end

  test "cache_key_for differs between users" do
    user_one = users(:one)
    user_two = users(:two)

    key_one = AvatarComponent.cache_key_for(user_one, 32)
    key_two = AvatarComponent.cache_key_for(user_two, 32)

    assert_not_equal key_one, key_two,
      "Cache key should differ between users"
  end
end
