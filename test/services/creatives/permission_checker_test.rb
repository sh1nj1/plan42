require "test_helper"

module Creatives
  class PermissionCheckerTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @other_user = users(:two)
      @creative = Creative.create!(user: @owner, description: "Test Creative", progress: 0.0)
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
      CreativeShare.create!(creative: @creative, user: nil, permission: "read")

      checker = Creatives::PermissionChecker.new(@creative, @other_user)
      assert checker.allowed?(:read)
      refute checker.allowed?(:write)
    end

    test "allows access via user-specific share" do
      CreativeShare.create!(creative: @creative, user: @other_user, permission: "write")

      checker = Creatives::PermissionChecker.new(@creative, @other_user)
      assert checker.allowed?(:read)
      assert checker.allowed?(:write)
      refute checker.allowed?(:admin)
    end

    test "uses cache for user share but fetches public share from DB" do
      # Setup public share (read)
      CreativeShare.create!(creative: @creative, user: nil, permission: "read")
      # Setup private share (write)
      CreativeShare.create!(creative: @creative, user: @other_user, permission: "write")

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
      # Setup public share (read)
      CreativeShare.create!(creative: @creative, user: nil, permission: "read")

      # Cache is empty (user has no private share)
      cache = {}

      Current.stub(:creative_share_cache, cache) do
        checker = Creatives::PermissionChecker.new(@creative, @other_user)
        assert checker.allowed?(:read)
      end
    end
  end
end
