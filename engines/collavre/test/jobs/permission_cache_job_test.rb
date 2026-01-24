require "test_helper"

class PermissionCacheJobTest < ActiveJob::TestCase
  setup do
    @owner = users(:one)
    @shared_user = users(:two)
    @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
    @child = Creative.create!(user: @owner, description: "Child", progress: 0.0, parent: @root)
    @grandchild = Creative.create!(user: @owner, description: "Grandchild", progress: 0.0, parent: @child)

    # Clear any queued jobs from setup callbacks
    clear_enqueued_jobs
  end

  test "cache_owner creates cache entry for creative owner" do
    # Clear existing cache from setup
    CreativeSharesCache.where(creative: @root, user: @owner).delete_all

    perform_enqueued_jobs do
      PermissionCacheJob.perform_later(:cache_owner, creative_id: @root.id)
    end

    cache = CreativeSharesCache.find_by(creative: @root, user: @owner)
    assert cache.present?
    assert cache.admin?
    assert_nil cache.source_share_id
  end

  test "cache_owner handles deleted creative gracefully" do
    creative_id = @root.id
    @root.destroy

    # Should not raise
    assert_nothing_raised do
      perform_enqueued_jobs do
        PermissionCacheJob.perform_later(:cache_owner, creative_id: creative_id)
      end
    end
  end

  test "update_owner updates cache when owner changes" do
    new_owner = users(:three)
    old_user_id = @owner.id

    # Manually update the creative first (simulating the change that triggers the job)
    @root.update_columns(user_id: new_owner.id)

    # Now call the job (simulating background execution after the model change)
    perform_enqueued_jobs do
      PermissionCacheJob.perform_later(:update_owner,
        creative_id: @root.id,
        old_user_id: old_user_id,
        new_user_id: new_owner.id
      )
    end

    # Old owner's cache should be removed (source_share_id nil)
    old_cache = CreativeSharesCache.find_by(creative: @root, user_id: old_user_id, source_share_id: nil)
    assert_nil old_cache

    # New owner should have cache
    new_cache = CreativeSharesCache.find_by(creative: @root, user_id: new_owner.id, source_share_id: nil)
    assert new_cache.present?
    assert new_cache.admin?
  end

  test "update_owner handles deleted creative gracefully" do
    creative_id = @root.id
    @root.destroy

    assert_nothing_raised do
      perform_enqueued_jobs do
        PermissionCacheJob.perform_later(:update_owner,
          creative_id: creative_id,
          old_user_id: @owner.id,
          new_user_id: users(:three).id
        )
      end
    end
  end

  test "rebuild_for_creative rebuilds cache after parent change" do
    other_owner = users(:three)
    other_tree = Creative.create!(user: other_owner, description: "Other Root", progress: 0.0)

    # Create shares (inline adapter executes jobs immediately)
    CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
    CreativeShare.create!(creative: other_tree, user: @shared_user, permission: "admin")

    # Verify initial state
    child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
    assert child_cache.read?

    # Move child to other_tree (job executes inline)
    @child.update!(parent: other_tree)

    # Child should now have admin from other_tree's share
    # Re-fetch instead of reload since rebuild_for_creative deletes and recreates entries
    child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
    assert child_cache.admin?
  end

  test "rebuild_for_creative handles deleted creative gracefully" do
    creative_id = @root.id
    @root.destroy

    assert_nothing_raised do
      perform_enqueued_jobs do
        PermissionCacheJob.perform_later(:rebuild_for_creative, creative_id: creative_id)
      end
    end
  end

  test "propagate_share creates cache entries for creative and descendants" do
    share = nil
    perform_enqueued_jobs do
      share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
    end

    assert CreativeSharesCache.exists?(creative: @root, user: @shared_user)
    assert CreativeSharesCache.exists?(creative: @child, user: @shared_user)
    assert CreativeSharesCache.exists?(creative: @grandchild, user: @shared_user)

    cache_entries = CreativeSharesCache.where(user: @shared_user)
    assert cache_entries.all? { |e| e.source_share_id == share.id }
    assert cache_entries.all? { |e| e.read? }
  end

  test "propagate_share handles deleted share gracefully" do
    share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
    share_id = share.id
    share.destroy

    clear_enqueued_jobs

    assert_nothing_raised do
      perform_enqueued_jobs do
        PermissionCacheJob.perform_later(:propagate_share, creative_share_id: share_id)
      end
    end
  end

  test "remove_share deletes cache and rebuilds from ancestors" do
    # Create parent and child shares
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "write")
      CreativeShare.create!(creative: @child, user: @shared_user, permission: "read")
    end

    child_share = CreativeShare.find_by(creative: @child, user: @shared_user)
    root_share = CreativeShare.find_by(creative: @root, user: @shared_user)

    # Verify grandchild has read from child_share
    grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
    assert_equal child_share.id, grandchild_cache.source_share_id

    # Delete child share
    perform_enqueued_jobs do
      child_share.destroy
    end

    # Grandchild should now have write from root_share
    grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
    assert_equal root_share.id, grandchild_cache.source_share_id
    assert grandchild_cache.write?
  end

  test "remove_share handles deleted creative gracefully" do
    share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
    share_id = share.id
    creative_id = @root.id
    user_id = @shared_user.id

    # Delete both share and creative
    share.destroy
    @root.destroy

    clear_enqueued_jobs

    assert_nothing_raised do
      perform_enqueued_jobs do
        PermissionCacheJob.perform_later(:remove_share,
          creative_share_id: share_id,
          creative_id: creative_id,
          user_id: user_id
        )
      end
    end
  end

  test "rebuild_user_cache_for_subtree rebuilds cache for specific user" do
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
    end

    # Delete cache manually to simulate stale state
    CreativeSharesCache.where(user: @shared_user).where.not(source_share_id: nil).delete_all

    # Rebuild should restore cache from ancestor share
    perform_enqueued_jobs do
      PermissionCacheJob.perform_later(:rebuild_user_cache_for_subtree,
        creative_id: @child.id,
        user_id: @shared_user.id
      )
    end

    assert CreativeSharesCache.exists?(creative: @child, user: @shared_user)
    assert CreativeSharesCache.exists?(creative: @grandchild, user: @shared_user)
  end

  test "rebuild_user_cache_for_subtree handles deleted creative gracefully" do
    creative_id = @root.id
    @root.destroy

    assert_nothing_raised do
      perform_enqueued_jobs do
        PermissionCacheJob.perform_later(:rebuild_user_cache_for_subtree,
          creative_id: creative_id,
          user_id: @shared_user.id
        )
      end
    end
  end

  test "cache is populated when creative is created" do
    creative = Creative.create!(user: @owner, description: "New Creative", progress: 0.0)

    # Verify cache entry was created (job executed inline)
    assert CreativeSharesCache.exists?(creative: creative, user: @owner, permission: :admin)
  end

  test "cache is updated when creative parent changes" do
    other_tree = Creative.create!(user: @owner, description: "Other Root", progress: 0.0)
    CreativeShare.create!(creative: other_tree, user: @shared_user, permission: "admin")

    # Initially child has no share cache for @shared_user
    refute CreativeSharesCache.exists?(creative: @child, user: @shared_user)

    # Move child to other_tree (job executes inline)
    @child.update!(parent: other_tree)

    # Child should now have admin from other_tree's share
    assert CreativeSharesCache.exists?(creative: @child, user: @shared_user, permission: :admin)
  end

  test "cache is populated when creative_share is created" do
    CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

    # Verify cache entries were created (job executed inline)
    assert CreativeSharesCache.exists?(creative: @root, user: @shared_user, permission: :read)
    assert CreativeSharesCache.exists?(creative: @child, user: @shared_user, permission: :read)
  end

  test "cache is cleared when creative_share is destroyed" do
    share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
    assert CreativeSharesCache.exists?(creative: @root, user: @shared_user)

    share.destroy

    # Cache should be cleared (job executed inline)
    refute CreativeSharesCache.exists?(creative: @root, user: @shared_user)
  end
end
