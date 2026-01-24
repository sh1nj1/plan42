require "test_helper"

module Creatives
  class PermissionCacheBuilderTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @shared_user = users(:two)
      perform_enqueued_jobs do
        @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
        @child = Creative.create!(user: @owner, description: "Child", progress: 0.0, parent: @root)
        @grandchild = Creative.create!(user: @owner, description: "Grandchild", progress: 0.0, parent: @child)
      end
    end

    test "propagate_share creates cache entries for creative and descendants" do
      share = nil
      perform_enqueued_jobs do
        share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
      end

      # Cache should have entries for root, child, and grandchild
      assert CreativeSharesCache.exists?(creative: @root, user: @shared_user)
      assert CreativeSharesCache.exists?(creative: @child, user: @shared_user)
      assert CreativeSharesCache.exists?(creative: @grandchild, user: @shared_user)

      # All entries should point to the same source_share
      cache_entries = CreativeSharesCache.where(user: @shared_user)
      assert cache_entries.all? { |e| e.source_share_id == share.id }
      assert cache_entries.all? { |e| e.read? }
    end

    test "propagate_share with no_access stores no_access in cache" do
      share = nil
      perform_enqueued_jobs do
        # First create a read share
        share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
      end
      assert_equal 3, CreativeSharesCache.where(user: @shared_user).count

      perform_enqueued_jobs do
        # Update to no_access should store no_access entries (not delete)
        share.update!(permission: "no_access")
      end

      # Entries still exist but with no_access permission
      assert_equal 3, CreativeSharesCache.where(user: @shared_user).count
      assert CreativeSharesCache.where(user: @shared_user).all?(&:no_access?)
    end

    test "remove_share deletes cache entries and rebuilds from ancestors" do
      parent_share = nil
      child_share = nil

      perform_enqueued_jobs do
        # Create a parent share
        parent_share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "write")

        # Create a child share (higher in tree specificity)
        child_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "read")
      end

      # Verify grandchild has read (from child_share)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert_equal child_share.id, grandchild_cache.source_share_id

      perform_enqueued_jobs do
        # Delete child share - grandchild should get write from parent share
        child_share.destroy
      end

      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert_equal parent_share.id, grandchild_cache.source_share_id
      assert grandchild_cache.write?
    end

    test "rebuild_for_creative handles parent_id change" do
      other_owner = users(:three)
      @other_tree = nil

      perform_enqueued_jobs do
        @other_tree = Creative.create!(user: other_owner, description: "Other Root", progress: 0.0)

        # Share root with user
        CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

        # Share other_tree with different permission
        CreativeShare.create!(creative: @other_tree, user: @shared_user, permission: "admin")
      end

      # Verify child has read from root's share
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      assert child_cache.read?

      perform_enqueued_jobs do
        # Move child to other_tree
        @child.update!(parent: @other_tree)
      end

      # Child and grandchild should now have admin from other_tree's share
      @child.reload
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)

      assert child_cache.admin?
      assert grandchild_cache.admin?
    end

    test "rebuild_for_creative preserves direct shares on moved subtree" do
      other_owner = users(:three)
      @other_tree = nil
      child_share = nil

      perform_enqueued_jobs do
        @other_tree = Creative.create!(user: other_owner, description: "Other Root", progress: 0.0)

        # Share other_tree with admin
        CreativeShare.create!(creative: @other_tree, user: @shared_user, permission: "admin")

        # Share child directly with write (this should be preserved after move)
        child_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "write")
      end

      # Verify child has write from its direct share
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      assert child_cache.write?
      assert_equal child_share.id, child_cache.source_share_id

      perform_enqueued_jobs do
        # Move child to other_tree
        @child.update!(parent: @other_tree)
      end

      # Child should still have write from its direct share (not overwritten by other_tree's admin)
      @child.reload
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      assert child_cache.write?, "Direct share on moved node should be preserved"
      assert_equal child_share.id, child_cache.source_share_id

      # Grandchild should have write inherited from child's direct share
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert grandchild_cache.write?, "Grandchild should inherit from child's direct share"
      assert_equal child_share.id, grandchild_cache.source_share_id
    end

    test "propagate_share handles public shares (user_id = nil)" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @root, user: nil, permission: "read")
      end

      # Cache should have entries for root, child, and grandchild with user_id = nil
      assert CreativeSharesCache.exists?(creative: @root, user_id: nil)
      assert CreativeSharesCache.exists?(creative: @child, user_id: nil)
      assert CreativeSharesCache.exists?(creative: @grandchild, user_id: nil)
    end

    test "upsert updates existing cache entries on permission change" do
      share = nil
      perform_enqueued_jobs do
        share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
      end

      root_cache = CreativeSharesCache.find_by(creative: @root, user: @shared_user)
      assert root_cache.read?

      perform_enqueued_jobs do
        # Update permission
        share.update!(permission: "write")
      end

      root_cache.reload
      assert root_cache.write?
    end

    test "closest share wins - order independent when parent share created first" do
      parent_share = nil
      child_share = nil

      perform_enqueued_jobs do
        # Create parent share first with write
        parent_share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "write")

        # Create child share with read
        child_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "read")
      end

      # Root should have write (from parent_share)
      root_cache = CreativeSharesCache.find_by(creative: @root, user: @shared_user)
      assert root_cache.write?
      assert_equal parent_share.id, root_cache.source_share_id

      # Child should have read (from child_share - closest wins)
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      assert child_cache.read?
      assert_equal child_share.id, child_cache.source_share_id

      # Grandchild should have read (inherited from child_share)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert grandchild_cache.read?
      assert_equal child_share.id, grandchild_cache.source_share_id
    end

    test "closest share wins - order independent when child share created first" do
      child_share = nil
      parent_share = nil

      perform_enqueued_jobs do
        # Create child share first with read
        child_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "read")

        # Create parent share with write
        parent_share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "write")
      end

      # Root should have write (from parent_share)
      root_cache = CreativeSharesCache.find_by(creative: @root, user: @shared_user)
      assert root_cache.write?
      assert_equal parent_share.id, root_cache.source_share_id

      # Child should still have read (from child_share - closest wins, not overwritten)
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      assert child_cache.read?
      assert_equal child_share.id, child_cache.source_share_id

      # Grandchild should have read (inherited from child_share, not overwritten)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert grandchild_cache.read?
      assert_equal child_share.id, grandchild_cache.source_share_id
    end
  end
end
