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
end
