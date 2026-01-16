require "test_helper"

module Creatives
  class PermissionCacheBuilderTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @shared_user = users(:two)
      @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
      @child = Creative.create!(user: @owner, description: "Child", progress: 0.0, parent: @root)
      @grandchild = Creative.create!(user: @owner, description: "Grandchild", progress: 0.0, parent: @child)
    end

    test "propagate_share creates cache entries for creative and descendants" do
      share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      # Cache should have entries for root, child, and grandchild
      assert CreativeSharesCache.exists?(creative: @root, user: @shared_user)
      assert CreativeSharesCache.exists?(creative: @child, user: @shared_user)
      assert CreativeSharesCache.exists?(creative: @grandchild, user: @shared_user)

      # All entries should point to the same source_share
      cache_entries = CreativeSharesCache.where(user: @shared_user)
      assert cache_entries.all? { |e| e.source_share_id == share.id }
      assert cache_entries.all? { |e| e.read? }
    end

    test "propagate_share with no_access removes cache entries" do
      # First create a read share
      share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")
      assert_equal 3, CreativeSharesCache.where(user: @shared_user).count

      # Update to no_access should remove cache entries
      share.update!(permission: "no_access")

      assert_equal 0, CreativeSharesCache.where(user: @shared_user).count
    end

    test "remove_share deletes cache entries and rebuilds from ancestors" do
      # Create a parent share
      parent_share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "write")

      # Create a child share (higher in tree specificity)
      child_share = CreativeShare.create!(creative: @child, user: @shared_user, permission: "read")

      # Verify grandchild has read (from child_share)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert_equal child_share.id, grandchild_cache.source_share_id

      # Delete child share - grandchild should get write from parent share
      child_share.destroy

      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)
      assert_equal parent_share.id, grandchild_cache.source_share_id
      assert grandchild_cache.write?
    end

    test "rebuild_for_creative handles parent_id change" do
      other_owner = users(:three)
      @other_tree = Creative.create!(user: other_owner, description: "Other Root", progress: 0.0)

      # Share root with user
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      # Share other_tree with different permission
      CreativeShare.create!(creative: @other_tree, user: @shared_user, permission: "admin")

      # Verify child has read from root's share
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      assert child_cache.read?

      # Move child to other_tree
      @child.update!(parent: @other_tree)

      # Child and grandchild should now have admin from other_tree's share
      @child.reload
      child_cache = CreativeSharesCache.find_by(creative: @child, user: @shared_user)
      grandchild_cache = CreativeSharesCache.find_by(creative: @grandchild, user: @shared_user)

      assert child_cache.admin?
      assert grandchild_cache.admin?
    end

    test "propagate_share handles public shares (user_id = nil)" do
      share = CreativeShare.create!(creative: @root, user: nil, permission: "read")

      # Cache should have entries for root, child, and grandchild with user_id = nil
      assert CreativeSharesCache.exists?(creative: @root, user_id: nil)
      assert CreativeSharesCache.exists?(creative: @child, user_id: nil)
      assert CreativeSharesCache.exists?(creative: @grandchild, user_id: nil)
    end

    test "upsert updates existing cache entries on permission change" do
      share = CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      root_cache = CreativeSharesCache.find_by(creative: @root, user: @shared_user)
      assert root_cache.read?

      # Update permission
      share.update!(permission: "write")

      root_cache.reload
      assert root_cache.write?
    end
  end
end
