require "test_helper"

class CreativePermissionCacheTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "owner@example.com", password: "secret", name: "Owner")
    @user1 = User.create!(email: "user1@example.com", password: "secret", name: "User1")
    @user2 = User.create!(email: "user2@example.com", password: "secret", name: "User2")
    Current.session = OpenStruct.new(user: @owner)

    # Clear cache before each test
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

  test "permission results are cached" do
    # Grant read permission to user1 on root
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Mock the permission calculation to verify caching
    checker = Creatives::PermissionChecker.new(@root, @user1)

    # First call should calculate and cache
    result1 = checker.allowed?(:read)
    assert result1

    # Verify cache key exists
    cache_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    cached_value = Rails.cache.read(cache_key)
    assert_equal true, cached_value

    # Second call should use cache (we can verify by checking it doesn't do DB queries)
    result2 = checker.allowed?(:read)
    assert result2
    assert_equal result1, result2
  end

  test "permission inheritance works with caching" do
    # Grant read permission to user1 on root
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Child should inherit permission from parent
    result = @child.has_permission?(@user1, :read)
    assert result

    # Verify child permission is cached
    cache_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    cached_value = Rails.cache.read(cache_key)
    assert_equal true, cached_value

    # Grandchild should also inherit
    result = @grandchild.has_permission?(@user1, :read)
    assert result

    # Verify grandchild permission is cached
    cache_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"
    cached_value = Rails.cache.read(cache_key)
    assert_equal true, cached_value
  end

  test "cache is invalidated when permission changes" do
    # Grant read permission to user1 on root
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permission (this will cache the result)
    result1 = @root.has_permission?(@user1, :read)
    assert result1

    # Verify cache exists
    cache_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(cache_key)

    # Change permission
    share.update!(permission: :write)

    # Cache should be cleared
    refute Rails.cache.exist?(cache_key)

    # New permission check should work correctly
    result2 = @root.has_permission?(@user1, :write)
    assert result2

    # Read permission should now be false (write >= read so this should still be true actually)
    result3 = @root.has_permission?(@user1, :read)
    assert result3  # write permission includes read
  end

  test "cache invalidation affects descendant permissions" do
    # Grant read permission to user1 on root
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permissions on all levels (this will cache them)
    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)

    # Verify all caches exist
    root_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    grandchild_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"

    assert Rails.cache.exist?(root_key)
    assert Rails.cache.exist?(child_key)
    assert Rails.cache.exist?(grandchild_key)

    # Change root permission to no_access
    share.update!(permission: :no_access)

    # All descendant caches should be cleared
    refute Rails.cache.exist?(root_key)
    refute Rails.cache.exist?(child_key)
    refute Rails.cache.exist?(grandchild_key)

    # Permissions should now be denied
    refute @root.has_permission?(@user1, :read)
    refute @child.has_permission?(@user1, :read)
    refute @grandchild.has_permission?(@user1, :read)
  end

  test "cache invalidation is selective - only affects specific user and creative tree" do
    # Grant permissions to both users
    share1 = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    share2 = CreativeShare.create!(creative: @root, user: @user2, permission: :write)

    # Check permissions for both users (caches results)
    assert @root.has_permission?(@user1, :read)
    assert @root.has_permission?(@user2, :read)
    assert @root.has_permission?(@user2, :write)
    assert @child.has_permission?(@user1, :read)
    assert @child.has_permission?(@user2, :write)

    # Verify all caches exist
    user1_root_read = "creative_permission:#{@root.id}:#{@user1.id}:read"
    user1_child_read = "creative_permission:#{@child.id}:#{@user1.id}:read"
    user2_root_read = "creative_permission:#{@root.id}:#{@user2.id}:read"
    user2_root_write = "creative_permission:#{@root.id}:#{@user2.id}:write"
    user2_child_write = "creative_permission:#{@child.id}:#{@user2.id}:write"

    assert Rails.cache.exist?(user1_root_read)
    assert Rails.cache.exist?(user1_child_read)
    assert Rails.cache.exist?(user2_root_read)
    assert Rails.cache.exist?(user2_root_write)
    assert Rails.cache.exist?(user2_child_write)

    # Change only user1's permission
    share1.update!(permission: :no_access)

    # Only user1's caches should be cleared
    refute Rails.cache.exist?(user1_root_read)
    refute Rails.cache.exist?(user1_child_read)

    # User2's caches should remain intact
    assert Rails.cache.exist?(user2_root_read)
    assert Rails.cache.exist?(user2_root_write)
    assert Rails.cache.exist?(user2_child_write)

    # Permissions should reflect the changes
    refute @root.has_permission?(@user1, :read)
    assert @root.has_permission?(@user2, :write)
  end

  test "cache invalidation works when share is destroyed" do
    # Grant read permission
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permission (caches result)
    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)

    # Verify caches exist
    root_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(root_key)
    assert Rails.cache.exist?(child_key)

    # Destroy the share
    share.destroy!

    # Caches should be cleared
    refute Rails.cache.exist?(root_key)
    refute Rails.cache.exist?(child_key)

    # Permissions should be denied (no share exists)
    refute @root.has_permission?(@user1, :read)
    refute @child.has_permission?(@user1, :read)
  end

  test "cache handles no_access override correctly" do
    # Grant read permission on root
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Override with no_access on child
    no_access_share = CreativeShare.create!(creative: @child, user: @user1, permission: :no_access)

    # Root should have access, child and grandchild should not
    assert @root.has_permission?(@user1, :read)
    refute @child.has_permission?(@user1, :read)
    refute @grandchild.has_permission?(@user1, :read)

    # Verify caching works
    root_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    grandchild_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"

    assert_equal true, Rails.cache.read(root_key)
    assert_equal false, Rails.cache.read(child_key)
    assert_equal false, Rails.cache.read(grandchild_key)

    # Remove no_access override
    no_access_share.destroy!

    # Child caches should be cleared
    refute Rails.cache.exist?(child_key)
    refute Rails.cache.exist?(grandchild_key)

    # Child should now inherit read permission from root
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)
  end

  test "different permission levels are cached independently" do
    # Grant write permission (which includes read)
    CreativeShare.create!(creative: @root, user: @user1, permission: :write)

    # Check different permission levels
    assert @root.has_permission?(@user1, :read)
    assert @root.has_permission?(@user1, :write)
    refute @root.has_permission?(@user1, :admin)

    # Verify separate cache entries exist
    read_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    write_key = "creative_permission:#{@root.id}:#{@user1.id}:write"
    admin_key = "creative_permission:#{@root.id}:#{@user1.id}:admin"

    assert_equal true, Rails.cache.read(read_key)
    assert_equal true, Rails.cache.read(write_key)
    assert_equal false, Rails.cache.read(admin_key)
  end
end
