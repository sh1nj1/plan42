require "test_helper"

module Collavre
  class CreativePresenceStoreTest < ActiveSupport::TestCase
    setup do
      @root_id = 999
      Rails.cache.delete(CreativePresenceStore.key(@root_id))
    end

    test "add adds user to list" do
      CreativePresenceStore.add(@root_id, 1)
      assert_equal [ 1 ], CreativePresenceStore.list(@root_id)
    end

    test "add does not duplicate user" do
      CreativePresenceStore.add(@root_id, 1)
      CreativePresenceStore.add(@root_id, 1)
      assert_equal [ 1 ], CreativePresenceStore.list(@root_id)
    end

    test "remove removes user from list" do
      CreativePresenceStore.add(@root_id, 1)
      CreativePresenceStore.add(@root_id, 2)
      CreativePresenceStore.remove(@root_id, 1)
      assert_equal [ 2 ], CreativePresenceStore.list(@root_id)
    end

    test "list returns empty array when no users" do
      assert_equal [], CreativePresenceStore.list(@root_id)
    end
  end
end
