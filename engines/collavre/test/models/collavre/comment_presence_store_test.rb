require "test_helper"

module Collavre
  class CommentPresenceStoreTest < ActiveSupport::TestCase
    setup do
      @ids = [ 9_901, 9_902, 9_903 ]
      @ids.each { |id| Rails.cache.delete(CommentPresenceStore.key(id)) }
    end

    test "list_many returns presence for every creative asked about" do
      CommentPresenceStore.add(9_901, 1)
      CommentPresenceStore.add(9_901, 2)
      CommentPresenceStore.add(9_902, 3)

      assert_equal(
        { 9_901 => [ 1, 2 ], 9_902 => [ 3 ], 9_903 => [] },
        CommentPresenceStore.list_many(@ids)
      )
    end

    # Callers index the result by creative id; an id missing from the hash would
    # make "nobody is here" indistinguishable from "we never asked".
    test "list_many reports an empty list rather than omitting a creative" do
      result = CommentPresenceStore.list_many([ 9_903 ])

      assert_equal [ 9_903 ], result.keys
      assert_equal [], result[9_903]
    end

    test "list_many agrees with list" do
      CommentPresenceStore.add(9_901, 7)

      assert_equal CommentPresenceStore.list(9_901), CommentPresenceStore.list_many([ 9_901 ]).fetch(9_901)
    end

    test "list_many with no ids does not touch the cache" do
      assert_equal({}, CommentPresenceStore.list_many([]))
    end

    test "list_many de-duplicates repeated ids" do
      CommentPresenceStore.add(9_901, 4)

      assert_equal({ 9_901 => [ 4 ] }, CommentPresenceStore.list_many([ 9_901, 9_901 ]))
    end
  end
end
