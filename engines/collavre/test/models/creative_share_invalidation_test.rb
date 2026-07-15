require "test_helper"

module Collavre
  # Covers the declarative permission-cache invalidation registry on
  # CreativeShare — the second write entry point, unified to mirror
  # Creative::Permissible so that a new share-mutation path can never
  # silently skip a required cache rebuild.
  #
  # The end-state semantics (which cache rows exist after each mutation) are
  # already pinned by CreativePermissionCacheTest. This file pins the dispatch
  # *mechanism*: the declarative map, which job each change enqueues, and that
  # an untracked change enqueues nothing.
  class CreativeShareInvalidationTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @user1 = users(:two)
      @user2 = users(:three)
      Current.session = OpenStruct.new(user: @owner)
      perform_enqueued_jobs do
        @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
        @other_root = Creative.create!(user: @owner, description: "Other root", progress: 0.0)
      end
    end

    teardown { Current.reset }

    test "registry declares the share-invalidating attributes" do
      map = CreativeShare::PERMISSION_INVALIDATING_ATTRIBUTES
      assert_equal :relocate, map["creative_id"]
      assert_equal :reassign, map["user_id"]
      assert_equal :repropagate, map["permission"]
    end

    test "creating a share enqueues a single propagate_share" do
      share = nil
      calls = capture_permission_cache_jobs do
        share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
      end
      # Filter to this share's dispatch; creating the recipient's inbox creative
      # (via notify_recipient) legitimately fires owner-cache jobs for a
      # different creative, which are not part of the share dispatcher.
      share_calls = calls.select { |_op, kw| kw[:creative_share_id] == share.id }
      assert_equal [ [ :propagate_share, { creative_share_id: share.id } ] ], share_calls
    end

    test "changing only permission re-propagates the share" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.update!(permission: :write)
      end
      assert_equal [ [ :propagate_share, { creative_share_id: share.id } ] ], calls
    end

    test "changing creative_id relocates: rebuild vacated old subtree then propagate" do
      share = create_share(@root, @user1, :read)
      old_creative_id = @root.id
      calls = capture_permission_cache_jobs do
        share.update!(creative: @other_root)
      end
      assert_includes calls,
        [ :rebuild_user_cache_for_subtree, { creative_id: old_creative_id, user_id: @user1.id } ]
      assert_includes calls, [ :propagate_share, { creative_share_id: share.id } ]
    end

    test "changing user_id reassigns: rebuild old user's subtree then propagate" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.update!(user: @user2)
      end
      assert_includes calls,
        [ :rebuild_user_cache_for_subtree, { creative_id: @root.id, user_id: @user1.id } ]
      assert_includes calls, [ :propagate_share, { creative_share_id: share.id } ]
    end

    test "an untracked attribute change enqueues no cache job" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.update!(shared_by_id: @user2.id)
      end
      assert_empty calls,
        "changing shared_by_id must not touch the permission cache"
    end

    test "destroying a share enqueues remove_share" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.destroy!
      end
      assert_equal [ [ :remove_share,
        { creative_share_id: share.id, creative_id: @root.id, user_id: @user1.id } ] ], calls
    end

    private

    def create_share(creative, user, permission)
      share = nil
      perform_enqueued_jobs do
        share = CreativeShare.create!(creative: creative, user: user, permission: permission)
      end
      share
    end

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
