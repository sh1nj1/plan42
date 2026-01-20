require "test_helper"

class CreativePermissionCacheTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "owner@example.com", password: TEST_PASSWORD, name: "Owner")
    @user1 = User.create!(email: "user1@example.com", password: TEST_PASSWORD, name: "User1")
    @user2 = User.create!(email: "user2@example.com", password: TEST_PASSWORD, name: "User2")
    Current.session = OpenStruct.new(user: @owner)

    # Create tree structure: root -> child -> grandchild
    perform_enqueued_jobs do
      @root = Creative.create!(user: @owner, description: "Root")
      @child = Creative.create!(user: @owner, parent: @root, description: "Child")
      @grandchild = Creative.create!(user: @owner, parent: @child, description: "Grandchild")
    end
  end

  teardown do
    Current.reset
  end

  test "permission cache entries are created when share is created" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end

    # Cache entries should exist for root, child, and grandchild
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)
    assert CreativeSharesCache.exists?(creative: @child, user: @user1)
    assert CreativeSharesCache.exists?(creative: @grandchild, user: @user1)
  end

  test "permission checks use cache table" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end

    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)
  end

  test "cache is updated when permission changes" do
    share = nil
    perform_enqueued_jobs do
      share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end

    cache_entry = CreativeSharesCache.find_by(creative: @root, user: @user1)
    assert cache_entry.read?

    perform_enqueued_jobs do
      share.update!(permission: :write)
    end

    cache_entry.reload
    assert cache_entry.write?
    assert @root.reload.has_permission?(@user1, :write)
  end

  test "cache invalidation affects descendant permissions" do
    share = nil
    perform_enqueued_jobs do
      share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end

    assert @root.has_permission?(@user1, :read)
    assert @child.has_permission?(@user1, :read)
    assert @grandchild.has_permission?(@user1, :read)

    perform_enqueued_jobs do
      # Change to no_access stores no_access entries
      share.update!(permission: :no_access)
    end

    # Cache entries should exist with no_access permission
    assert CreativeSharesCache.exists?(creative: @root, user: @user1, permission: :no_access)
    assert CreativeSharesCache.exists?(creative: @child, user: @user1, permission: :no_access)
    assert CreativeSharesCache.exists?(creative: @grandchild, user: @user1, permission: :no_access)

    # Permissions should be denied
    refute @root.reload.has_permission?(@user1, :read)
    refute @child.reload.has_permission?(@user1, :read)
    refute @grandchild.reload.has_permission?(@user1, :read)
  end

  test "cache is cleared when share is destroyed" do
    share = nil
    perform_enqueued_jobs do
      share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end
    assert @root.has_permission?(@user1, :read)
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)

    perform_enqueued_jobs do
      share.destroy!
    end

    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    refute @root.reload.has_permission?(@user1, :read)
  end

  test "cache handles no_access override correctly" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end
    assert @child.has_permission?(@user1, :read)

    # Override with no_access
    no_access_share = nil
    perform_enqueued_jobs do
      no_access_share = CreativeShare.create!(creative: @child, user: @user1, permission: :no_access)
    end

    # no_access stores no_access entries for child and descendants
    assert CreativeSharesCache.exists?(creative: @child, user: @user1, permission: :no_access)
    assert CreativeSharesCache.exists?(creative: @grandchild, user: @user1, permission: :no_access)

    refute @child.reload.has_permission?(@user1, :read)
    refute @grandchild.reload.has_permission?(@user1, :read)

    # Remove override
    perform_enqueued_jobs do
      no_access_share.destroy!
    end

    # Should revert to inherited read from root's share
    assert @child.reload.has_permission?(@user1, :read)
    assert @grandchild.reload.has_permission?(@user1, :read)
  end

  test "cache is rebuilt when creative parent changes" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end
    assert @child.has_permission?(@user1, :read)

    new_parent = nil
    perform_enqueued_jobs do
      new_parent = Creative.create!(user: @owner, description: "New Parent")
      @child.update!(parent: new_parent)
    end

    # Child moved, permission should be denied (new_parent has no share)
    refute @child.reload.has_permission?(@user1, :read)
    refute CreativeSharesCache.exists?(creative: @child, user: @user1)
  end

  test "public share creates cache entries" do
    refute @root.has_permission?(@user1, :read)

    perform_enqueued_jobs do
      # Add public share (user: nil)
      CreativeShare.create!(creative: @root, user: nil, permission: "read")
    end

    # Public share should create cache entries with user_id = nil
    assert CreativeSharesCache.exists?(creative: @root, user_id: nil)
    assert CreativeSharesCache.exists?(creative: @child, user_id: nil)

    # Access should be granted via public share
    assert @root.reload.has_permission?(@user1, :read)
  end

  test "no_access overrides public share" do
    perform_enqueued_jobs do
      # Add public share
      CreativeShare.create!(creative: @root, user: nil, permission: "read")
    end
    assert @root.reload.has_permission?(@user1, :read)

    perform_enqueued_jobs do
      # Add no_access for specific user - should override public share
      CreativeShare.create!(creative: @root, user: @user1, permission: :no_access)
    end

    # User1 should be denied even though public share exists
    refute @root.reload.has_permission?(@user1, :read)

    # User2 should still have access via public share
    assert @root.has_permission?(@user2, :read)
  end

  test "cache is updated when CreativeShare creative_id changes" do
    other_root = nil
    share = nil
    perform_enqueued_jobs do
      other_root = Creative.create!(user: @owner, description: "Other")
      share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end

    assert @root.has_permission?(@user1, :read)
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)

    perform_enqueued_jobs do
      share.update!(creative: other_root)
    end

    # Old cache should be removed, new cache created
    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    assert CreativeSharesCache.exists?(creative: other_root, user: @user1)

    refute @root.reload.has_permission?(@user1, :read)
    assert other_root.reload.has_permission?(@user1, :read)
  end

  test "cache is updated when CreativeShare user_id changes" do
    share = nil
    perform_enqueued_jobs do
      share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
    end
    assert @root.has_permission?(@user1, :read)

    perform_enqueued_jobs do
      share.update!(user: @user2)
    end

    # User1 should no longer have cache entries
    refute CreativeSharesCache.exists?(creative: @root, user: @user1)
    # User2 should have cache entries
    assert CreativeSharesCache.exists?(creative: @root, user: @user2)

    refute @root.reload.has_permission?(@user1, :read)
    assert @root.has_permission?(@user2, :read)
  end

  test "changing share user_id preserves unrelated shares for old user" do
    root_share = nil
    child_share = nil
    perform_enqueued_jobs do
      # Share root with user1
      root_share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
      # Share child with user1 (separate share)
      child_share = CreativeShare.create!(creative: @child, user: @user1, permission: :write)
    end

    # Verify both shares are cached
    assert CreativeSharesCache.exists?(creative: @root, user: @user1)
    assert CreativeSharesCache.exists?(creative: @child, user: @user1)
    child_cache = CreativeSharesCache.find_by(creative: @child, user: @user1)
    assert child_cache.write?
    assert_equal child_share.id, child_cache.source_share_id

    perform_enqueued_jobs do
      # Change root_share to user2
      root_share.update!(user: @user2)
    end

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

    perform_enqueued_jobs do
      @root.update!(user: @user1)
    end

    # Owner has cache entry with admin permission
    assert CreativeSharesCache.exists?(creative: @root, user: @user1, permission: :admin)
    assert @root.reload.has_permission?(@user1, :admin)
    assert @root.has_permission?(@user1, :read)
  end

  test "rebuild paths propagate no_access correctly" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: nil, permission: "read")  # public
      CreativeShare.create!(creative: @root, user: @user1, permission: :no_access)
    end

    # user1 should be denied due to no_access
    refute @root.reload.has_permission?(@user1, :read)

    new_parent = nil
    perform_enqueued_jobs do
      # Move child to force rebuild
      new_parent = Creative.create!(user: @owner, description: "New")
      @child.update!(parent: new_parent)
      @child.update!(parent: @root)
    end

    # user1 should still be denied after rebuild
    refute @root.reload.has_permission?(@user1, :read)
    refute @child.reload.has_permission?(@user1, :read)
  end

  test "children_with_permission respects no_access over public share" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: nil, permission: "read")  # public
    end

    # user1 can see children via public share
    assert_includes @root.children_with_permission(@user1, :read), @child

    perform_enqueued_jobs do
      # Add no_access for user1 on root
      CreativeShare.create!(creative: @root, user: @user1, permission: :no_access)
    end

    # user1 should NOT see children anymore
    refute_includes @root.reload.children_with_permission(@user1, :read), @child
  end

  test "children_with_permission user-specific weaker permission overrides public stronger permission" do
    perform_enqueued_jobs do
      # Public share has admin
      CreativeShare.create!(creative: @root, user: nil, permission: "admin")
      # User1 has explicit read (weaker than required write)
      CreativeShare.create!(creative: @root, user: @user1, permission: "read")
    end

    # user1 should NOT see child with :write requirement
    # Even though public has admin, user-specific entry takes precedence
    refute_includes @root.children_with_permission(@user1, :write), @child

    # But user1 should see child with :read requirement (matches their permission)
    assert_includes @root.children_with_permission(@user1, :read), @child
  end
end
