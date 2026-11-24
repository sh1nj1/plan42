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

    # --- rebuild_for_creative: ancestor shares are scoped to the rebuilt subtree ---

    test "rebuild_for_creative applies every ancestor user's share to a new leaf" do
      third_user = users(:three)
      root_share = child_share = nil
      perform_enqueued_jobs do
        root_share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
        child_share = CreativeShare.create!(creative: @child, user: third_user, permission: "write")
      end

      leaf = nil
      perform_enqueued_jobs do
        leaf = Creative.create!(user: @owner, description: "Leaf", progress: 0.0, parent: @grandchild)
      end

      shared_cache = CreativeSharesCache.find_by(creative: leaf, user: @shared_user)
      third_cache = CreativeSharesCache.find_by(creative: leaf, user: third_user)
      assert shared_cache.read?
      assert_equal root_share.id, shared_cache.source_share_id
      assert third_cache.write?
      assert_equal child_share.id, third_cache.source_share_id
      assert CreativeSharesCache.find_by(creative: leaf, user: @owner, source_share_id: nil).admin?
    end

    test "rebuild_for_creative uses the closest ancestor share for the same user" do
      child_share = nil
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
        child_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "write")
      end

      Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(@grandchild)

      cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert cache.write?
      assert_equal child_share.id, cache.source_share_id
      assert_equal 1, CreativeSharesCache.where(creative: @grandchild, user: @shared_user).count
    end

    test "rebuild_for_creative propagates an ancestor public share into the subtree" do
      public_share = nil
      perform_enqueued_jobs do
        public_share = CreativeShare.create!(creative: @root, user: nil, permission: "read")
      end
      CreativeSharesCache.where(creative: [ @child, @grandchild ], user_id: nil).delete_all

      Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(@child)

      [ @child, @grandchild ].each do |creative|
        rows = CreativeSharesCache.where(creative: creative, user_id: nil)
        assert_equal 1, rows.count
        assert rows.first.read?
        assert_equal public_share.id, rows.first.source_share_id
      end
    end

    test "rebuild_for_creative stores an ancestor no_access share alongside a public share" do
      no_access_share = nil
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @root, user: nil, permission: "read")
        no_access_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "no_access")
      end

      leaf = nil
      perform_enqueued_jobs do
        leaf = Creative.create!(user: @owner, description: "Leaf", progress: 0.0, parent: @grandchild)
      end

      user_cache = CreativeSharesCache.find_by(creative: leaf, user: @shared_user)
      assert user_cache.no_access?
      assert_equal no_access_share.id, user_cache.source_share_id
      assert CreativeSharesCache.find_by(creative: leaf, user_id: nil).read?
    end

    test "rebuild_for_creative lets an in-subtree direct share override the ancestor share" do
      root_share = grandchild_share = nil
      perform_enqueued_jobs do
        root_share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
        grandchild_share = CreativeShare.create!(creative: @grandchild, user: @shared_user, permission: "no_access")
      end

      Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(@child)

      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert child_cache.read?
      assert_equal root_share.id, child_cache.source_share_id
      assert grandchild_cache.no_access?
      assert_equal grandchild_share.id, grandchild_cache.source_share_id
    end

    test "rebuild_for_creative rebuilds a moved subtree from the new ancestors only" do
      third_user = users(:three)
      other_root = other_share = nil
      perform_enqueued_jobs do
        other_root = Creative.create!(user: @owner, description: "Other Root", progress: 0.0)
        CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
        other_share = CreativeShare.create!(creative: other_root, user: third_user, permission: "write")
      end

      perform_enqueued_jobs { @child.update!(parent: other_root) }

      [ @child, @grandchild ].each do |creative|
        assert_not CreativeSharesCache.exists?(creative: creative, user: @shared_user),
                   "stale share from the old ancestor must be removed"
        cache = CreativeSharesCache.find_by(creative: creative, user: third_user)
        assert cache.write?
        assert_equal other_share.id, cache.source_share_id
      end
    end

    test "rebuild_for_creative does not touch cache rows outside the rebuilt subtree" do
      sibling = nil
      perform_enqueued_jobs do
        sibling = Creative.create!(user: @owner, description: "Sibling", progress: 0.0, parent: @root)
        CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
        CreativeShare.create!(creative: @root, user: nil, permission: "read")
      end
      outside_ids = [ @root.id, @child.id, sibling.id ]
      before = outside_rows_snapshot(outside_ids)
      # Tamper with an outside row: a rebuild scoped to the subtree must not repair it.
      # (The old whole-subtree propagation would have rewritten it back to read.)
      CreativeSharesCache.where(creative: sibling, user: @shared_user)
                         .update_all(permission: CreativeShare.permissions[:write])

      writes = capture_cache_writes do
        Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(@grandchild)
      end

      assert CreativeSharesCache.find_by(creative: sibling, user: @shared_user).write?
      CreativeSharesCache.where(creative: sibling, user: @shared_user)
                         .update_all(permission: CreativeShare.permissions[:read])
      assert_equal before, outside_rows_snapshot(outside_ids)
      assert CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user).read?
      assert CreativeSharesCache.find_by(creative: @grandchild, user_id: nil).read?
      # One upsert for the user share, one insert for the public share, one owner upsert:
      # all of them for the rebuilt leaf only.
      assert_equal 3, writes.size
    end

    test "rebuild_for_creative on a root creative without ancestors keeps direct shares" do
      share = nil
      perform_enqueued_jobs do
        share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
      end

      Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(@root)

      rows = CreativeSharesCache.where(user: @shared_user)
      assert_equal [ @root.id, @child.id, @grandchild.id ].sort, rows.pluck(:creative_id).sort
      assert rows.all? { |row| row.source_share_id == share.id }
    end

    test "propagate_share upserts large subtrees in batches" do
      batch_size = Collavre::Creatives::PermissionCacheBuilder::UPSERT_BATCH_SIZE
      Collavre::Creatives::PermissionCacheBuilder.send(:remove_const, :UPSERT_BATCH_SIZE)
      Collavre::Creatives::PermissionCacheBuilder.const_set(:UPSERT_BATCH_SIZE, 2)
      share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      writes = capture_cache_writes do
        Collavre::Creatives::PermissionCacheBuilder.propagate_share(share)
      end

      assert_equal 2, writes.count { |sql| sql.match?(/INSERT INTO "creative_shares_caches"/i) }
      assert_equal 3, CreativeSharesCache.where(user: @shared_user, source_share_id: share.id).count
    ensure
      Collavre::Creatives::PermissionCacheBuilder.send(:remove_const, :UPSERT_BATCH_SIZE)
      Collavre::Creatives::PermissionCacheBuilder.const_set(:UPSERT_BATCH_SIZE, batch_size)
    end

    private

    def outside_rows_snapshot(creative_ids)
      CreativeSharesCache.where(creative_id: creative_ids)
                         .order(:id)
                         .pluck(:id, :creative_id, :user_id, :permission, :source_share_id)
    end

    def capture_cache_writes
      writes = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        writes << sql if sql.match?(/\A\s*(INSERT|UPDATE)/i) && sql.include?("creative_shares_caches")
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      writes
    end
  end
end
