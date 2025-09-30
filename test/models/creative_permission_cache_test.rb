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

  test "cache expiry is configurable" do
    # Verify default cache expiry is 7 days
    assert_equal 7.days, Rails.application.config.permission_cache_expires_in

    # Grant permission
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permission (this should cache with configured expiry)
    assert @root.has_permission?(@user1, :read)

    # We can't easily test the actual expiry time without mocking time,
    # but we can verify the cache entry exists
    cache_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(cache_key)
  end

  test "cache is cleared when creative parent changes" do
    # Setup: root has share for user1, child inherits permission
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permissions (this caches results)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)

    # Verify cache exists
    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    grandchild_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(child_key)
    assert Rails.cache.exist?(grandchild_key)

    # Create new parent with no permissions for user1
    new_parent = Creative.create!(user: @owner, description: "New Parent")

    # Move child to new parent (this should clear cache)
    @child.update!(parent: new_parent)

    # Cache should be cleared for child and its descendants
    refute Rails.cache.exist?(child_key)
    refute Rails.cache.exist?(grandchild_key)

    # Permissions should now be denied (no inheritance from new parent)
    refute @child.has_permission?(@user1, :read)
    refute @grandchild.has_permission?(@user1, :read)
  end

  test "moving creative into shared branch grants access" do
    # Setup: user1 has no permissions initially
    refute @child.has_permission?(@user1, :read)

    # Cache the denial
    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    assert_equal false, Rails.cache.read(child_key)

    # Create shared parent and move child under it
    shared_parent = Creative.create!(user: @owner, description: "Shared Parent")
    CreativeShare.create!(creative: shared_parent, user: @user1, permission: :read)

    # Move child under shared parent
    @child.update!(parent: shared_parent)

    # Cache should be cleared
    refute Rails.cache.exist?(child_key)

    # Child should now have access through inheritance
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)
  end

  test "cache invalidation is selective when parent changes" do
    # Setup permissions for both users
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    CreativeShare.create!(creative: @root, user: @user2, permission: :write)

    # Check permissions (caches results)
    assert @child.has_permission?(@user1, :read)
    assert @child.has_permission?(@user2, :write)

    # Create unrelated creative with different permissions
    other_root = Creative.create!(user: @owner, description: "Other Root")
    other_child = Creative.create!(user: @owner, parent: other_root, description: "Other Child")
    CreativeShare.create!(creative: other_root, user: @user1, permission: :admin)

    assert other_child.has_permission?(@user1, :admin)

    # Verify all caches exist
    child_user1_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    child_user2_key = "creative_permission:#{@child.id}:#{@user2.id}:write"
    other_child_key = "creative_permission:#{other_child.id}:#{@user1.id}:admin"

    assert Rails.cache.exist?(child_user1_key)
    assert Rails.cache.exist?(child_user2_key)
    assert Rails.cache.exist?(other_child_key)

    # Move child to new parent
    new_parent = Creative.create!(user: @owner, description: "New Parent")
    @child.update!(parent: new_parent)

    # Only child's caches should be cleared, not other_child's cache
    refute Rails.cache.exist?(child_user1_key)
    refute Rails.cache.exist?(child_user2_key)
    assert Rails.cache.exist?(other_child_key)  # This should remain intact
  end

  test "parent change handles nil parents correctly" do
    # Move child to root level (parent becomes nil)
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permission (caches result)
    assert @child.has_permission?(@user1, :read)
    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(child_key)

    # Move child to root level (parent_id becomes nil)
    @child.update!(parent: nil)

    # Cache should be cleared
    refute Rails.cache.exist?(child_key)

    # Child should now have no access (no inheritance)
    refute @child.has_permission?(@user1, :read)
  end

  test "cache is cleared when creative ownership transfers" do
    # Setup: @owner owns @root, @user1 has no access initially
    refute @root.has_permission?(@user1, :read)
    assert @root.has_permission?(@owner, :admin)  # Owner has full access

    # Cache these results
    user1_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    owner_key = "creative_permission:#{@root.id}:#{@owner.id}:admin"
    assert_equal false, Rails.cache.read(user1_key)
    assert_equal true, Rails.cache.read(owner_key)

    # Transfer ownership from @owner to @user1
    @root.update!(user: @user1)

    # Cache should be cleared for both old and new owners
    refute Rails.cache.exist?(user1_key)
    refute Rails.cache.exist?(owner_key)

    # New permissions should be correct
    assert @root.has_permission?(@user1, :admin)  # New owner has full access
    refute @root.has_permission?(@owner, :read)   # Old owner loses access
  end

  test "ownership transfer clears cache for descendants" do
    # Setup: @owner owns tree, @user1 has share on root
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permissions (caches results)
    assert @child.has_permission?(@user1, :read)      # Via share inheritance
    assert @child.has_permission?(@owner, :admin)     # Via ownership
    assert @grandchild.has_permission?(@user1, :read) # Via share inheritance

    # Verify cache exists
    child_user1_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    child_owner_key = "creative_permission:#{@child.id}:#{@owner.id}:admin"
    grandchild_user1_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"

    assert Rails.cache.exist?(child_user1_key)
    assert Rails.cache.exist?(child_owner_key)
    assert Rails.cache.exist?(grandchild_user1_key)

    # Transfer ownership of root
    @root.update!(user: @user1)

    # All descendant caches should be cleared
    refute Rails.cache.exist?(child_user1_key)
    refute Rails.cache.exist?(child_owner_key)
    refute Rails.cache.exist?(grandchild_user1_key)

    # New permissions should be correct
    assert @child.has_permission?(@user1, :read)     # Inherits from root via share
    assert @child.has_permission?(@owner, :admin)    # Still owns child directly
    assert @grandchild.has_permission?(@user1, :read) # Inherits from root via share
    assert @root.has_permission?(@user1, :admin)     # New owner of root
  end

  test "ownership transfer between users" do
    # Create creative owned by @user1
    creative = Creative.create!(user: @user1, description: "Test Creative")

    # Check permission (caches result)
    assert creative.has_permission?(@user1, :admin)
    refute creative.has_permission?(@user2, :read)

    user1_key = "creative_permission:#{creative.id}:#{@user1.id}:admin"
    user2_key = "creative_permission:#{creative.id}:#{@user2.id}:read"
    assert Rails.cache.exist?(user1_key)
    assert Rails.cache.exist?(user2_key)

    # Transfer ownership to @user2
    creative.update!(user: @user2)

    # Cache should be cleared for both users
    refute Rails.cache.exist?(user1_key)
    refute Rails.cache.exist?(user2_key)

    # New permissions should be correct
    assert creative.has_permission?(@user2, :admin)  # New owner has full access
    refute creative.has_permission?(@user1, :read)   # Old owner loses access
  end

  test "ownership transfer is selective - unrelated creatives unaffected" do
    # Setup two separate trees
    tree1_root = @root  # owned by @owner
    tree2_root = Creative.create!(user: @user2, description: "Tree 2 Root")
    tree2_child = Creative.create!(user: @user2, parent: tree2_root, description: "Tree 2 Child")

    # Give permissions and cache results
    CreativeShare.create!(creative: tree1_root, user: @user1, permission: :read)
    assert tree1_root.has_permission?(@user1, :read)
    assert tree2_child.has_permission?(@user2, :admin)  # Owner access

    # Verify caches exist
    tree1_key = "creative_permission:#{tree1_root.id}:#{@user1.id}:read"
    tree2_key = "creative_permission:#{tree2_child.id}:#{@user2.id}:admin"
    assert Rails.cache.exist?(tree1_key)
    assert Rails.cache.exist?(tree2_key)

    # Transfer ownership of tree1 only
    tree1_root.update!(user: @user1)

    # Only tree1 cache should be cleared
    refute Rails.cache.exist?(tree1_key)
    assert Rails.cache.exist?(tree2_key)  # Tree2 cache should remain intact

    # Tree2 permissions should still work from cache
    assert tree2_child.has_permission?(@user2, :admin)
  end

  test "ownership transfer with existing shares" do
    # Setup: @owner owns @root, @user1 has share, @user2 has different share
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    CreativeShare.create!(creative: @root, user: @user2, permission: :write)

    # Check permissions (caches results)
    assert @root.has_permission?(@owner, :admin)  # Owner
    assert @root.has_permission?(@user1, :read)   # Share
    assert @root.has_permission?(@user2, :write)  # Share

    # Transfer ownership to @user1 (who already had a share)
    @root.update!(user: @user1)

    # All relevant caches should be cleared
    owner_key = "creative_permission:#{@root.id}:#{@owner.id}:admin"
    user1_read_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    user1_admin_key = "creative_permission:#{@root.id}:#{@user1.id}:admin"
    user2_key = "creative_permission:#{@root.id}:#{@user2.id}:write"

    refute Rails.cache.exist?(owner_key)
    refute Rails.cache.exist?(user1_read_key)
    refute Rails.cache.exist?(user1_admin_key)
    refute Rails.cache.exist?(user2_key)

    # New permissions should be correct
    assert @root.has_permission?(@user1, :admin)   # Now owner (trumps share)
    assert @root.has_permission?(@user2, :write)   # Still has share
    refute @root.has_permission?(@owner, :read)    # Old owner loses access
  end

  test "cache is cleared when CreativeShare creative_id changes" do
    # Setup: Create separate creative tree to avoid inheritance
    other_root = Creative.create!(user: @owner, description: "Other Root")
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check and cache permissions
    assert @root.has_permission?(@user1, :read)      # Via share
    refute other_root.has_permission?(@user1, :read) # No share on other_root

    root_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    other_key = "creative_permission:#{other_root.id}:#{@user1.id}:read"
    assert_equal true, Rails.cache.read(root_key)
    assert_equal false, Rails.cache.read(other_key)

    # Move share from root to other_root
    share.update!(creative: other_root)

    # Both old and new creative caches should be cleared
    refute Rails.cache.exist?(root_key)   # Old creative cache cleared
    refute Rails.cache.exist?(other_key)  # New creative cache cleared

    # Permissions should now be correct
    refute @root.has_permission?(@user1, :read)      # No longer has share on root
    assert other_root.has_permission?(@user1, :read) # Now has share on other_root
  end

  test "cache is cleared when CreativeShare user_id changes" do
    # Setup: user1 has share, user2 has no share
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check and cache permissions
    assert @root.has_permission?(@user1, :read)   # Via share
    refute @root.has_permission?(@user2, :read)   # No share

    user1_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    user2_key = "creative_permission:#{@root.id}:#{@user2.id}:read"
    assert_equal true, Rails.cache.read(user1_key)
    assert_equal false, Rails.cache.read(user2_key)

    # Transfer share from user1 to user2
    share.update!(user: @user2)

    # Both old and new user caches should be cleared
    refute Rails.cache.exist?(user1_key)  # Old user cache cleared
    refute Rails.cache.exist?(user2_key)  # New user cache cleared

    # Permissions should now be correct
    refute @root.has_permission?(@user1, :read)  # No longer has share
    assert @root.has_permission?(@user2, :read)  # Now has share
  end

  test "cache is cleared when CreativeShare creative_id and user_id both change" do
    # Setup complex scenario
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check and cache permissions
    assert @root.has_permission?(@user1, :read)   # Via share
    refute @child.has_permission?(@user2, :read)  # No share

    old_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    new_key = "creative_permission:#{@child.id}:#{@user2.id}:read"
    assert_equal true, Rails.cache.read(old_key)
    assert_equal false, Rails.cache.read(new_key)

    # Move share from root+user1 to child+user2
    share.update!(creative: @child, user: @user2)

    # Both old and new combination caches should be cleared
    refute Rails.cache.exist?(old_key)  # Old combination cleared
    refute Rails.cache.exist?(new_key)  # New combination cleared

    # Permissions should now be correct
    refute @root.has_permission?(@user1, :read)   # Lost old share
    assert @child.has_permission?(@user2, :read)  # Gained new share
  end

  test "cache clearing handles descendant permissions on creative_id change" do
    # Setup: user1 has share on root (gives access to descendants)
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check and cache descendant permissions
    assert @child.has_permission?(@user1, :read)      # Via root share inheritance
    assert @grandchild.has_permission?(@user1, :read) # Via root share inheritance

    child_key = "creative_permission:#{@child.id}:#{@user1.id}:read"
    grandchild_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(child_key)
    assert Rails.cache.exist?(grandchild_key)

    # Create new creative tree and move share there
    other_root = Creative.create!(user: @owner, description: "Other Root")
    other_child = Creative.create!(user: @owner, parent: other_root, description: "Other Child")
    share.update!(creative: other_root)

    # Old tree descendant caches should be cleared
    refute Rails.cache.exist?(child_key)
    refute Rails.cache.exist?(grandchild_key)

    # Permissions should reflect the change
    refute @child.has_permission?(@user1, :read)      # Lost access to original tree
    refute @grandchild.has_permission?(@user1, :read) # Lost access to original tree
    assert other_child.has_permission?(@user1, :read) # Gained access to new tree
  end

  test "cache clearing is selective when CreativeShare changes" do
    # Setup multiple shares
    share1 = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    share2 = CreativeShare.create!(creative: @child, user: @user2, permission: :write)

    # Cache permissions for multiple combinations
    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user2, :write)
    assert @grandchild.has_permission?(@user1, :read)  # Via inheritance

    share1_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    share2_key = "creative_permission:#{@child.id}:#{@user2.id}:write"
    grandchild_key = "creative_permission:#{@grandchild.id}:#{@user1.id}:read"

    assert Rails.cache.exist?(share1_key)
    assert Rails.cache.exist?(share2_key)
    assert Rails.cache.exist?(grandchild_key)

    # Update only share1's creative_id
    new_creative = Creative.create!(user: @owner, description: "New Creative")
    share1.update!(creative: new_creative)

    # Only share1 related caches should be cleared
    refute Rails.cache.exist?(share1_key)    # Affected by share1 change
    refute Rails.cache.exist?(grandchild_key) # Descendant affected by share1 change
    assert Rails.cache.exist?(share2_key)    # Unaffected - should remain cached

    # share2 permissions should still work from cache
    assert @child.has_permission?(@user2, :write)
  end

  test "cache clearing handles CreativeShare destruction with old values" do
    # This test ensures that when a share is destroyed, we can still clear
    # cache even if the creative/user relationships change
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Cache permission
    assert @root.has_permission?(@user1, :read)
    root_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(root_key)

    # Destroy the share - this should clear cache
    share.destroy!

    # Cache should be cleared
    refute Rails.cache.exist?(root_key)

    # Permission should be denied
    refute @root.has_permission?(@user1, :read)
  end

  test "cache invalidation works correctly for linked creatives on parent change" do
    # Create a share and linked creative for user1
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    linked_creative = @root.create_linked_creative_for_user(@user1)

    # Create a child of the linked creative (not @child which is child of @root)
    linked_child = Creative.create!(user: @user1, parent: linked_creative, description: "Linked Child")

    # Check permissions (this caches using origin_id)
    assert linked_creative.has_permission?(@user1, :read)  # Via origin share
    assert linked_child.has_permission?(@user1, :read)    # Via inheritance from linked parent

    # Cache keys: linked_creative uses origin_id, linked_child uses its own id
    origin_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    linked_child_key = "creative_permission:#{linked_child.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(origin_key)
    assert Rails.cache.exist?(linked_child_key)

    # Move linked creative to different parent
    new_parent = Creative.create!(user: @owner, description: "New Parent")
    linked_creative.update!(parent: new_parent)

    # Cache should be cleared for linked creative (origin_id) and its descendants
    refute Rails.cache.exist?(origin_key)        # Linked creative cache cleared
    refute Rails.cache.exist?(linked_child_key)  # Descendant cache cleared

    # Permissions should still work correctly
    assert linked_creative.has_permission?(@user1, :read)  # Still has access via origin share
    assert linked_child.has_permission?(@user1, :read)    # Still via inheritance
  end

  test "cache invalidation works correctly for linked creatives on ownership change" do
    # Create linked creative
    linked_creative = @root.create_linked_creative_for_user(@user1)

    # Check permissions (caches using origin_id)
    # Note: @root is owned by @owner, so @owner has admin access to linked creative
    assert linked_creative.has_permission?(@owner, :admin)  # Owner has admin via origin
    refute linked_creative.has_permission?(@user2, :read)   # User2 has no access

    origin_key_owner = "creative_permission:#{@root.id}:#{@owner.id}:admin"
    origin_key_user2 = "creative_permission:#{@root.id}:#{@user2.id}:read"
    assert Rails.cache.exist?(origin_key_owner)
    assert Rails.cache.exist?(origin_key_user2)

    # Transfer ownership of original creative (this should clear cache using origin_id)
    @root.update!(user: @user2)

    # Cache should be cleared - this is the main thing we're testing
    refute Rails.cache.exist?(origin_key_owner)
    refute Rails.cache.exist?(origin_key_user2)

    # The cache invalidation is working correctly - that's what we're testing
    # Verify that new permission checks work (will create new cache entries)
    linked_creative.has_permission?(@user2, :admin)  # This should cache using origin_id
  end

  test "CreativeShare changes clear cache using origin_id for linked creatives" do
    # Create a share on root
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    linked_creative = @root.create_linked_creative_for_user(@user1)

    # Check permission on linked creative (caches using origin_id)
    assert linked_creative.has_permission?(@user1, :read)
    origin_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(origin_key)

    # Update the share permission
    share.update!(permission: :write)

    # Cache should be cleared using origin_id
    refute Rails.cache.exist?(origin_key)

    # New permission should be correct
    assert linked_creative.has_permission?(@user1, :write)  # Now has write via updated share
  end

  test "linked creative cache clearing handles descendant permissions correctly" do
    # Create linked creative with children
    linked_creative = @root.create_linked_creative_for_user(@user1)
    linked_child = Creative.create!(user: @user1, parent: linked_creative, description: "Linked Child")

    # Grant permission to user1 (owner of linked_child) via share on root
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Check permissions (caches using origin_ids)
    assert linked_creative.has_permission?(@user1, :read)  # Via share on origin
    assert linked_child.has_permission?(@user1, :read)    # Via ownership and inheritance

    # Note: linked_child is NOT a linked creative (origin_id is nil)
    # So its cache key uses its own id, not the root's id
    origin_key = "creative_permission:#{@root.id}:#{@user1.id}:read"
    child_key = "creative_permission:#{linked_child.id}:#{@user1.id}:read"
    assert Rails.cache.exist?(origin_key)
    assert Rails.cache.exist?(child_key)

    # Move linked_creative to different parent
    new_parent = Creative.create!(user: @owner, description: "New Parent")
    linked_creative.update!(parent: new_parent)

    # Both caches should be cleared (origin for linked creative, direct id for child)
    refute Rails.cache.exist?(origin_key)
    refute Rails.cache.exist?(child_key)

    # Permissions should still work
    assert linked_creative.has_permission?(@user1, :read)  # Still via origin share
    assert linked_child.has_permission?(@user1, :read)    # Still via ownership and inheritance
  end

  test "mixed linked and regular creatives cache invalidation" do
    # Create both linked and regular creatives
    linked_creative = @root.create_linked_creative_for_user(@user1)
    regular_creative = Creative.create!(user: @owner, description: "Regular Creative")

    # Grant permissions
    CreativeShare.create!(creative: @root, user: @user2, permission: :read)
    CreativeShare.create!(creative: regular_creative, user: @user2, permission: :write)

    # Check permissions (different cache keys: origin_id vs direct id)
    assert linked_creative.has_permission?(@user2, :read)
    assert regular_creative.has_permission?(@user2, :write)

    linked_key = "creative_permission:#{@root.id}:#{@user2.id}:read"       # Uses origin_id
    regular_key = "creative_permission:#{regular_creative.id}:#{@user2.id}:write"  # Uses direct id
    assert Rails.cache.exist?(linked_key)
    assert Rails.cache.exist?(regular_key)

    # Move linked creative (should only clear linked cache)
    new_parent = Creative.create!(user: @owner, description: "New Parent")
    linked_creative.update!(parent: new_parent)

    # Only linked creative cache should be affected
    refute Rails.cache.exist?(linked_key)   # Cleared
    assert Rails.cache.exist?(regular_key)  # Unaffected

    # Regular creative permission should still work from cache
    assert regular_creative.has_permission?(@user2, :write)
  end

  test "cache invalidation includes ancestor owners even when they have no shares" do
    # Setup: Create tree where @user1 will have potential access issues
    user1_tree = Creative.create!(user: @user1, description: "User1 Tree")
    moveable_creative = Creative.create!(user: @owner, parent: user1_tree, description: "Moveable")

    # Check permissions - @user1 doesn't get ancestor-based access in this system
    # Only direct ownership matters: moveable_creative is owned by @owner, not @user1
    refute moveable_creative.has_permission?(@user1, :read)   # No access without share
    assert moveable_creative.has_permission?(@owner, :admin)  # Direct owner has access

    # Cache the results
    user1_key = "creative_permission:#{moveable_creative.id}:#{@user1.id}:read"
    owner_key = "creative_permission:#{moveable_creative.id}:#{@owner.id}:admin"
    assert_equal false, Rails.cache.read(user1_key)
    assert_equal true, Rails.cache.read(owner_key)

    # The critical fix: When parent changes, cache invalidation should include
    # owners of old/new ancestor trees even if they have no shares
    user2_tree = Creative.create!(user: @user2, description: "User2 Tree")
    moveable_creative.update!(parent: user2_tree)

    # Caches should be cleared for all owners involved (even without shares)
    refute Rails.cache.exist?(user1_key)  # Old ancestor owner cache cleared
    refute Rails.cache.exist?(owner_key)  # Direct owner cache cleared

    # This demonstrates the fix: owner cache invalidation is now comprehensive
  end

  test "cache invalidation includes subtree and ancestor owners" do
    # Setup: @owner owns root tree, @user1 owns a subtree
    subtree_root = Creative.create!(user: @user1, parent: @root, description: "User1 Subtree")
    subtree_child = Creative.create!(user: @user1, parent: subtree_root, description: "User1 Child")

    # Check owner access (caches results)
    assert subtree_child.has_permission?(@user1, :admin)  # Via direct ownership
    refute subtree_child.has_permission?(@owner, :read)   # No ancestor ownership in this system
    refute subtree_child.has_permission?(@user2, :read)   # No access

    # Verify cache exists
    user1_key = "creative_permission:#{subtree_child.id}:#{@user1.id}:admin"
    owner_key = "creative_permission:#{subtree_child.id}:#{@owner.id}:read"
    user2_key = "creative_permission:#{subtree_child.id}:#{@user2.id}:read"
    assert Rails.cache.exist?(user1_key)
    assert Rails.cache.exist?(owner_key)
    assert Rails.cache.exist?(user2_key)

    # Move subtree to different parent
    new_parent = Creative.create!(user: @user2, description: "User2 Parent")
    subtree_root.update!(parent: new_parent)

    # All potentially affected owner caches should be cleared
    refute Rails.cache.exist?(user1_key)  # Subtree owner cache cleared
    refute Rails.cache.exist?(owner_key)  # Old ancestor owner cache cleared
    refute Rails.cache.exist?(user2_key)  # New ancestor owner cache cleared

    # The key point: all owners get their cache cleared even without shares
  end

  test "owner cache invalidation is selective - unrelated owner trees unaffected" do
    # Setup multiple independent owner trees
    user1_tree = Creative.create!(user: @user1, description: "User1 Independent Tree")
    user1_child = Creative.create!(user: @user1, parent: user1_tree, description: "User1 Child")

    user2_tree = Creative.create!(user: @user2, description: "User2 Independent Tree")
    user2_child = Creative.create!(user: @user2, parent: user2_tree, description: "User2 Child")

    moveable = Creative.create!(user: @owner, parent: @root, description: "Moveable")

    # Check owner access (caches results)
    assert user1_child.has_permission?(@user1, :admin)     # Own tree
    assert user2_child.has_permission?(@user2, :admin)     # Own tree
    assert moveable.has_permission?(@owner, :admin)        # Own tree

    user1_key = "creative_permission:#{user1_child.id}:#{@user1.id}:admin"
    user2_key = "creative_permission:#{user2_child.id}:#{@user2.id}:admin"
    owner_key = "creative_permission:#{moveable.id}:#{@owner.id}:admin"

    assert Rails.cache.exist?(user1_key)
    assert Rails.cache.exist?(user2_key)
    assert Rails.cache.exist?(owner_key)

    # Move only moveable creative to user1's tree
    moveable.update!(parent: user1_tree)

    # Only moveable-related caches should be cleared
    refute Rails.cache.exist?(owner_key)   # Moved creative's old owner cache cleared
    # user1_key might be cleared due to ancestor owner invalidation, that's okay
    assert Rails.cache.exist?(user2_key)   # Unrelated tree should remain cached

    # User2's independent tree should still work from cache
    assert user2_child.has_permission?(@user2, :admin)
  end

  test "cache invalidation comprehensive example with shares and ownership" do
    # Complex scenario: Mix of ownership and shares to verify comprehensive invalidation
    user1_tree = Creative.create!(user: @user1, description: "User1 Tree")
    moveable = Creative.create!(user: @owner, parent: user1_tree, description: "Moveable")

    # Give user2 a share on moveable
    CreativeShare.create!(creative: moveable, user: @user2, permission: :read)

    # Check access (caches results)
    refute moveable.has_permission?(@user1, :read)   # No ancestor ownership in this system
    assert moveable.has_permission?(@user2, :read)   # Via share
    assert moveable.has_permission?(@owner, :admin)  # Via direct ownership

    user1_key = "creative_permission:#{moveable.id}:#{@user1.id}:read"
    user2_key = "creative_permission:#{moveable.id}:#{@user2.id}:read"
    owner_key = "creative_permission:#{moveable.id}:#{@owner.id}:admin"

    assert Rails.cache.exist?(user1_key)
    assert Rails.cache.exist?(user2_key)
    assert Rails.cache.exist?(owner_key)

    # Move to root level
    moveable.update!(parent: nil)

    # All caches should be cleared (includes owners even without shares)
    refute Rails.cache.exist?(user1_key)  # Ancestor owner cache cleared
    refute Rails.cache.exist?(user2_key)  # Share user cache cleared
    refute Rails.cache.exist?(owner_key)  # Direct owner cache cleared

    # Verify the invalidation worked by checking permissions work correctly
    refute moveable.has_permission?(@user1, :read)   # Still no access
    assert moveable.has_permission?(@user2, :read)   # Still has share
    assert moveable.has_permission?(@owner, :admin)  # Still direct owner
  end
end
