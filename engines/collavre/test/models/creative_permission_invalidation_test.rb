require "test_helper"

module Collavre
  # Covers the declarative permission-cache invalidation registry on Creative
  # and the origin_id immutability guard.
  class CreativePermissionInvalidationTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @other = users(:two)
      perform_enqueued_jobs do
        @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
        @other_parent = Creative.create!(user: @owner, description: "Other parent", progress: 0.0)
        @creative = Creative.create!(user: @owner, description: "Child", progress: 0.0, parent: @root)
      end
    end

    test "registry declares the permission-invalidating attributes" do
      assert_equal :rebuild, Creative::Permissible::PERMISSION_INVALIDATING_ATTRIBUTES["parent_id"]
      assert_equal :rebuild_owner, Creative::Permissible::PERMISSION_INVALIDATING_ATTRIBUTES["user_id"]
      assert_equal :rebuild, Creative::Permissible::PERMISSION_INVALIDATING_ATTRIBUTES["origin_id"]
    end

    test "changing parent_id enqueues a subtree rebuild" do
      calls = capture_permission_cache_jobs do
        @creative.update!(parent: @other_parent)
      end
      assert_includes calls, [ :rebuild_for_creative, { creative_id: @creative.id } ]
    end

    test "changing user_id enqueues an owner-cache move" do
      calls = capture_permission_cache_jobs do
        @creative.update!(user: @other)
      end
      assert_includes calls,
        [ :update_owner, { creative_id: @creative.id, old_user_id: @owner.id, new_user_id: @other.id } ]
    end

    test "an untracked attribute change enqueues no rebuild" do
      calls = capture_permission_cache_jobs do
        @creative.update!(description: "Renamed")
      end
      rebuild_ops = calls.map(&:first)
      refute_includes rebuild_ops, :rebuild_for_creative
      refute_includes rebuild_ops, :update_owner
    end

    test "origin_id is immutable once persisted" do
      origin_a = @root
      origin_b = @other_parent
      linked = nil
      perform_enqueued_jobs do
        linked = Creative.create!(origin: origin_a, user: @other, parent_id: nil)
      end

      # attr_readonly promotes the "origin_id is immutable" invariant to a
      # model-level guard that rejects any repoint of a persisted link.
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        linked.update!(origin_id: origin_b.id)
      end

      linked.reload
      assert_equal origin_a.id, linked.origin_id,
        "origin_id must not change on a persisted record (attr_readonly guard)"
    end

    private

    def capture_permission_cache_jobs(&block)
      calls = []
      recorder = lambda do |operation, **kwargs|
        calls << [ operation, kwargs ]
        nil
      end
      PermissionCacheJob.stub(:perform_later, recorder, &block)
      calls
    end
  end
end
