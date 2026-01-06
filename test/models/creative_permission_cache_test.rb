require "test_helper"

class CreativePermissionCacheTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "owner@example.com", password: "secret", name: "Owner")
    @user1 = User.create!(email: "user1@example.com", password: "secret", name: "User1")
    @user2 = User.create!(email: "user2@example.com", password: "secret", name: "User2")
    Current.session = OpenStruct.new(user: @owner)

    Rails.cache.clear

    # Create tree structure: root -> child -> grandchild
    @root = Creative.create!(user: @owner, description: "Root")
    @child = Creative.create!(user: @owner, parent: @root, description: "Child")
    @grandchild = Creative.create!(user: @owner, parent: @child, description: "Grandchild")
  end

  teardown do
    Current.reset
    Rails.cache.clear
  end

  # Helper to generate the expected cache key using versioning
  def cache_key(creative, user, permission)
    # Reload creative to get latest updated_at for cache_key_with_version
    creative.reload
    "creative_permission:#{creative.cache_key_with_version}:#{user.id}:#{permission}"
  end

  test "permission results are cached" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    checker = Creatives::PermissionChecker.new(@root, @user1)

    # First call
    assert checker.allowed?(:read)

    key = cache_key(@root, @user1, :read)
    assert Rails.cache.exist?(key)
    assert_equal true, Rails.cache.read(key)

    # Second call uses cache (implicitly tested by logic, explicitly by key presence)
    assert checker.allowed?(:read)
  end

  test "permission inheritance works with caching" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    assert @child.reload.has_permission?(@user1, :read)
    assert Rails.cache.exist?(cache_key(@child, @user1, :read))

    assert @grandchild.reload.has_permission?(@user1, :read)
    assert Rails.cache.exist?(cache_key(@grandchild, @user1, :read))
  end

  test "cache is invalidated (rotated) when permission changes" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Cache read
    assert @root.has_permission?(@user1, :read)
    old_key = cache_key(@root, @user1, :read)
    assert Rails.cache.exist?(old_key)

    # Change to write (touches creative)
    share.update!(permission: :write)

    # New check
    assert @root.reload.has_permission?(@user1, :write)
    new_key = cache_key(@root, @user1, :write)

    # Key should have changed due to touch
    refute_equal old_key, new_key
    assert Rails.cache.exist?(new_key)
  end

  test "cache invalidation affects descendant permissions" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Cache all
    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)

    old_child_key = cache_key(@child, @user1, :read)

    # Change root permission
    share.update!(permission: :no_access)

    # Descendants should be touched by logic in CreativeShare/Creative
    # Verify permissions are denied
    refute @root.reload.has_permission?(@user1, :read)
    refute @child.reload.has_permission?(@user1, :read)
    refute @grandchild.reload.has_permission?(@user1, :read)

    # New keys should be generated
    new_child_key = cache_key(@child, @user1, :read)
    refute_equal old_child_key, new_child_key
    assert Rails.cache.exist?(new_child_key)
    assert_equal false, Rails.cache.read(new_child_key)
  end

  test "cache invalidation works when share is destroyed" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @root.has_permission?(@user1, :read)
    old_key = cache_key(@root, @user1, :read)

    share.destroy!

    refute @root.reload.has_permission?(@user1, :read)
    new_key = cache_key(@root, @user1, :read)

    refute_equal old_key, new_key
    assert Rails.cache.exist?(new_key)
    assert_equal false, Rails.cache.read(new_key)
  end

  test "cache handles no_access override correctly" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @child.has_permission?(@user1, :read)

    # Override
    no_val_share = CreativeShare.create!(creative: @child, user: @user1, permission: :no_access)

    refute @child.reload.has_permission?(@user1, :read)
    refute @grandchild.reload.has_permission?(@user1, :read) # Inherits no_access from child? Or calculation?
    # Logic: share on child is no_access. PermissionChecker finds it and denies.

    # Remove override
    no_val_share.destroy!

    # Should revert to inherited read
    assert @child.reload.has_permission?(@user1, :read)
    assert @grandchild.reload.has_permission?(@user1, :read)
  end

  test "cache is cleared/rotated when creative parent changes" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @child.has_permission?(@user1, :read)
    old_key = cache_key(@child, @user1, :read)

    new_parent = Creative.create!(user: @owner, description: "New Parent")
    @child.update!(parent: new_parent)

    # Child moved, should be touched. Permissions recalculated (denied).
    refute @child.reload.has_permission?(@user1, :read)
    new_key = cache_key(@child, @user1, :read)

    refute_equal old_key, new_key
  end

  test "public share invalidation" do
    # Deny first
    refute @root.has_permission?(@user1, :read)
    old_key = cache_key(@root, @user1, :read)

    # Add public share
    CreativeShare.create!(creative: @root, user: nil, permission: "read")

    # Access granted?
    assert @root.reload.has_permission?(@user1, :read)
    new_key = cache_key(@root, @user1, :read)

    refute_equal old_key, new_key
  end

  test "cache is cleared when CreativeShare creative_id changes" do
    other_root = Creative.create!(user: @owner, description: "Other")
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    assert @root.has_permission?(@user1, :read)
    old_root_key = cache_key(@root, @user1, :read)

    share.update!(creative: other_root)

    refute @root.reload.has_permission?(@user1, :read)
    assert other_root.reload.has_permission?(@user1, :read)
  end

  test "cache is cleared when CreativeShare user_id changes" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @root.has_permission?(@user1, :read)
    old_key = cache_key(@root, @user1, :read)

    share.update!(user: @user2)

    # Creative touched. Key rotated.
    # User1 check -> new key -> Not found -> Calc -> Deny. Correct.
    refute @root.reload.has_permission?(@user1, :read)
    new_key = cache_key(@root, @user1, :read)
    refute_equal old_key, new_key

    assert @root.has_permission?(@user2, :read)
  end

  test "ownership transfer updates permissions and cache" do
    refute @root.has_permission?(@user1, :read)
    old_key = cache_key(@root, @user1, :read)

    @root.update!(user: @user1)

    # Creative touched by update.
    assert @root.reload.has_permission?(@user1, :admin) # Owner
    new_key = cache_key(@root, @user1, :admin) # Different permission checked usually

    # Check read again
    assert @root.has_permission?(@user1, :read)
  end
end
