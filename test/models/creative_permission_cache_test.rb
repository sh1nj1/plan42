require "test_helper"

class CreativePermissionCacheTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "owner@example.com", password: "secret", name: "Owner")
    @user1 = User.create!(email: "user1@example.com", password: "secret", name: "User1")
    @user2 = User.create!(email: "user2@example.com", password: "secret", name: "User2")
    Current.session = OpenStruct.new(user: @owner)

    # Create tree structure: root -> child -> grandchild
    @root = Creative.create!(user: @owner, description: "Root")
    @child = Creative.create!(user: @owner, parent: @root, description: "Child")
    @grandchild = Creative.create!(user: @owner, parent: @child, description: "Grandchild")
  end

  teardown do
    Current.reset
  end

  test "permission cache entries are created when share is created" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    # Cache entries should exist for root, child, and grandchild
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)
    assert CreativeSharesCache.exists?(creative: @child, user: @user1)
    assert CreativeSharesCache.exists?(creative: @grandchild, user: @user1)
  end

  test "permission checks use cache table" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)
  end

  test "cache is updated when permission changes" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    cache_entry = CreativeSharesCache.find_by(creative: @root, user: @user1)
    assert cache_entry.read?

    share.update!(permission: :write)

    cache_entry.reload
    assert cache_entry.write?
    assert @root.reload.has_permission?(@user1, :write)
  end

  test "cache invalidation affects descendant permissions" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)

    # Change to no_access removes cache entries
    share.update!(permission: :no_access)

    # Cache entries should be deleted
    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    refute CreativeSharesCache.exists?(creative: @child, user: @user1)
    refute CreativeSharesCache.exists?(creative: @grandchild, user: @user1)

    # Permissions should be denied
    refute @root.reload.has_permission?(@user1, :read)
    refute @child.reload.has_permission?(@user1, :read)
    refute @grandchild.reload.has_permission?(@user1, :read)
  end

  test "cache is cleared when share is destroyed" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @root.has_permission?(@user1, :read)
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)

    share.destroy!

    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    refute @root.reload.has_permission?(@user1, :read)
  end

  test "cache handles no_access override correctly" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @child.has_permission?(@user1, :read)

    # Override with no_access
    no_access_share = CreativeShare.create!(creative: @child, user: @user1, permission: :no_access)

    # no_access removes cache entries for child and descendants
    refute CreativeSharesCache.exists?(creative: @child, user: @user1)
    refute CreativeSharesCache.exists?(creative: @grandchild, user: @user1)

    refute @child.reload.has_permission?(@user1, :read)
    refute @grandchild.reload.has_permission?(@user1, :read)

    # Remove override
    no_access_share.destroy!

    # Should revert to inherited read from root's share
    assert @child.reload.has_permission?(@user1, :read)
    assert @grandchild.reload.has_permission?(@user1, :read)
  end

  test "cache is rebuilt when creative parent changes" do
    CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @child.has_permission?(@user1, :read)

    new_parent = Creative.create!(user: @owner, description: "New Parent")
    @child.update!(parent: new_parent)

    # Child moved, permission should be denied (new_parent has no share)
    refute @child.reload.has_permission?(@user1, :read)
    refute CreativeSharesCache.exists?(creative: @child, user: @user1)
  end

  test "public share creates cache entries" do
    refute @root.has_permission?(@user1, :read)

    # Add public share (user: nil)
    CreativeShare.create!(creative: @root, user: nil, permission: "read")

    # Public share should create cache entries with user_id = nil
    assert CreativeSharesCache.exists?(creative: @root, user_id: nil)
    assert CreativeSharesCache.exists?(creative: @child, user_id: nil)

    # Access should be granted via public share
    assert @root.reload.has_permission?(@user1, :read)
  end

  test "cache is updated when CreativeShare creative_id changes" do
    other_root = Creative.create!(user: @owner, description: "Other")
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)

    assert @root.has_permission?(@user1, :read)
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)

    share.update!(creative: other_root)

    # Old cache should be removed, new cache created
    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    assert CreativeSharesCache.exists?(creative: other_root, user: @user1)

    refute @root.reload.has_permission?(@user1, :read)
    assert other_root.reload.has_permission?(@user1, :read)
  end

  test "cache is updated when CreativeShare user_id changes" do
    share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    assert @root.has_permission?(@user1, :read)

    share.update!(user: @user2)

    # User1 should no longer have cache entries
    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    # User2 should have cache entries
    assert CreativeSharesCache.exists?(creative: @root, user: @user2)

    refute @root.reload.has_permission?(@user1, :read)
    assert @root.has_permission?(@user2, :read)
  end

  test "changing share user_id preserves unrelated shares for old user" do
    # Share root with user1
    root_share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    # Share child with user1 (separate share)
    child_share = CreativeShare.create!(creative: @child, user: @user1, permission: :write)

    # Verify both shares are cached
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)
    assert CreativeSharesCache.exists?(creative: @child, user: @user1)
    child_cache = CreativeSharesCache.find_by(creative: @child, user: @user1)
    assert child_cache.write?
    assert_equal child_share.id, child_cache.source_share_id

    # Change root_share to user2
    root_share.update!(user: @user2)

    # User1 should still have access to child (from child_share)
    assert CreativeSharesCache.exists?(creative: @child, user: @user1)
    child_cache = CreativeSharesCache.find_by(creative: @child, user: @user1)
    assert child_cache.write?, "Child share should be preserved"
    assert_equal child_share.id, child_cache.source_share_id

    # User1 should no longer have access to root
    refute CreativeSharesCache.exists?(creative: @root, user: @user1)

    # User2 should have access to root (and descendants via inheritance)
    assert CreativeSharesCache.exists?(creative: @root, user: @user2)
  end

  test "ownership creates cache entries with admin permission" do
    refute @root.has_permission?(@user1, :read)

    @root.update!(user: @user1)

    # Owner has cache entry with admin permission
    assert CreativeSharesCache.exists?(creative: @root, user: @user1, permission: :admin)
    assert @root.reload.has_permission?(@user1, :admin)
    assert @root.has_permission?(@user1, :read)
  end
end
