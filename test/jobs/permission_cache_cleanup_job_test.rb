require "test_helper"

class PermissionCacheCleanupJobTest < ActiveJob::TestCase
  setup do
    @user = User.create!(email: "cleanup@example.com", password: "password", name: "Cleanup User")
    @creative = Creative.create!(user: @user, description: "Test Creative")
  end

  test "removes cache rows for deleted creatives" do
    # Get the cache entry created by callbacks
    cache = CreativeSharesCache.find_by(creative_id: @creative.id, user_id: @user.id)
    assert cache, "Cache entry should exist"

    # Delete creative directly (bypass callbacks)
    Creative.where(id: @creative.id).delete_all

    assert CreativeSharesCache.exists?(cache.id)

    PermissionCacheCleanupJob.perform_now

    refute CreativeSharesCache.exists?(cache.id)
  end

  test "removes cache rows for deleted users" do
    other_user = User.create!(email: "other@example.com", password: "password", name: "Other")

    # Create share to generate cache entry for other_user
    share = CreativeShare.create!(creative: @creative, user: other_user, permission: :read)
    cache = CreativeSharesCache.find_by(creative_id: @creative.id, user_id: other_user.id)
    assert cache, "Cache entry should exist for other_user"

    # Delete user directly (bypass callbacks)
    CreativeShare.where(id: share.id).delete_all
    User.where(id: other_user.id).delete_all

    assert CreativeSharesCache.exists?(cache.id)

    PermissionCacheCleanupJob.perform_now

    refute CreativeSharesCache.exists?(cache.id)
  end

  test "preserves cache rows with null user_id (public shares)" do
    # Create public share cache entry directly
    cache = CreativeSharesCache.create!(
      creative_id: @creative.id,
      user_id: nil,
      permission: :read
    )

    PermissionCacheCleanupJob.perform_now

    assert CreativeSharesCache.exists?(cache.id)
  end

  test "removes cache rows for deleted shares" do
    other_user = User.create!(email: "other2@example.com", password: "password", name: "Other2")
    share = CreativeShare.create!(creative: @creative, user: other_user, permission: :write)

    cache = CreativeSharesCache.find_by(creative_id: @creative.id, user_id: other_user.id)
    assert cache, "Cache entry should exist"
    assert_equal share.id, cache.source_share_id

    # Delete share directly (bypass callbacks)
    CreativeShare.where(id: share.id).delete_all

    assert CreativeSharesCache.exists?(cache.id)

    PermissionCacheCleanupJob.perform_now

    refute CreativeSharesCache.exists?(cache.id)
  end

  test "preserves valid cache rows" do
    # Cache entry already created by callbacks
    cache = CreativeSharesCache.find_by(creative_id: @creative.id, user_id: @user.id)
    assert cache, "Cache entry should exist"

    PermissionCacheCleanupJob.perform_now

    assert CreativeSharesCache.exists?(cache.id)
  end
end
