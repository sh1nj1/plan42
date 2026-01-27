require "test_helper"

module Creatives
  class PermissionCheckerTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @other_user = users(:two)
      perform_enqueued_jobs do
        @creative = Creative.create!(user: @owner, description: "Test Creative", progress: 0.0)
      end
    end

    test "allows access for owner" do
      checker = Creatives::PermissionChecker.new(@creative, @owner)
      assert checker.allowed?(:read)
      assert checker.allowed?(:write)
      assert checker.allowed?(:admin)
    end

    test "denies access for unconnected user" do
      checker = Creatives::PermissionChecker.new(@creative, @other_user)
      refute checker.allowed?(:read)
    end

    test "allows read access for logged-in user via public share" do
      # Create public share
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @creative, user: nil, permission: "read")
      end

      checker = Creatives::PermissionChecker.new(@creative, @other_user)
      assert checker.allowed?(:read)
      refute checker.allowed?(:write)
    end

    test "allows access via user-specific share" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @creative, user: @other_user, permission: "write")
      end

      checker = Creatives::PermissionChecker.new(@creative, @other_user)
      assert checker.allowed?(:read)
      assert checker.allowed?(:write)
      refute checker.allowed?(:admin)
    end

    test "uses cache for user share but fetches public share from DB" do
      perform_enqueued_jobs do
        # Setup public share (read)
        CreativeShare.create!(creative: @creative, user: nil, permission: "read")
        # Setup private share (write)
        CreativeShare.create!(creative: @creative, user: @other_user, permission: "write")
      end

      # Simulate controller cache (only contains USER share)
      user_share = CreativeShare.find_by(user: @other_user, creative: @creative)
      cache = { @creative.id => user_share }

      # Inject cache into Current
      Current.stub(:creative_share_cache, cache) do
        checker = Creatives::PermissionChecker.new(@creative, @other_user)
        # Should result in 'write' because user share (cached) is higher than public share (db)
        assert checker.allowed?(:write)
      end
    end

    test "falls back to public share when user share not in cache" do
      perform_enqueued_jobs do
        # Setup public share (read)
        CreativeShare.create!(creative: @creative, user: nil, permission: "read")
      end

      # Cache is empty (user has no private share)
      cache = {}

      Current.stub(:creative_share_cache, cache) do
        checker = Creatives::PermissionChecker.new(@creative, @other_user)
        assert checker.allowed?(:read)
      end
    end

    test "invalides cache when public share is added (via touch)" do
      # 1. Initially deny access and cache it
      checker = Creatives::PermissionChecker.new(@creative, @other_user)
      refute checker.allowed?(:read)

      # 2. Add public share. This should touch @creative.
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @creative, user: nil, permission: "read")
      end
      @creative.reload # Ensure we see the updated timestamp behavior if checking logic directly, though new Checker instance will re-read.

      # 3. New checker should see allowed?(:read) because key changed or cache expired
      # Note: Real Rails cache with cache_key_with_version handles this automatically.
      # We just need to verify logic works in integration or by checking cache keys if we weren't mocking previously.

      # Since we are not stubbing Current.creative_share_cache here, it uses Rails.cache directly in PermissionChecker.
      checker_new = Creatives::PermissionChecker.new(@creative, @other_user)
      assert checker_new.allowed?(:read), "Should allow read after adding public share even if previously denied cached"
    end
  end
end
