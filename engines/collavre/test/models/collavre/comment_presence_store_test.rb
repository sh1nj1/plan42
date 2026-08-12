require "test_helper"

module Collavre
  class CommentPresenceStoreTest < ActiveSupport::TestCase
    setup do
      @ids = [ 9_901, 9_902, 9_903 ]
      @ids.each do |id|
        Rails.cache.delete(CommentPresenceStore.key(id))
        Rails.cache.delete(CommentPresenceStore.lock_key(id))
        (1..10).each do |user_id|
          Rails.cache.delete(CommentPresenceStore.topic_key(id, user_id))
          Rails.cache.delete(CommentPresenceStore.subscriptions_key(id, user_id))
          %w[first second all archived orphan].each do |subscription_id|
            Rails.cache.delete(CommentPresenceStore.subscription_lease_key(id, user_id, subscription_id))
          end
        end
      end
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

    test "tracks the topic a present user is viewing" do
      CommentPresenceStore.add(9_901, 4)
      CommentPresenceStore.set_topic(9_901, 4, 12)

      assert_equal 12, CommentPresenceStore.topic_for(9_901, 4)

      CommentPresenceStore.remove(9_901, 4)
      assert_nil CommentPresenceStore.topic_for(9_901, 4)
    end

    test "distinguishes All Messages from a missing topic report" do
      CommentPresenceStore.set_topic(9_901, 4, nil, rendered_topic_ids: [ 12 ], rendered_legacy_topic: true)

      assert_nil CommentPresenceStore.topic_for(9_901, 4)
      assert CommentPresenceStore.viewing_all_topics?(9_901, 4)
      assert_equal [ CommentPresenceStore::ALL_TOPICS, 12, CommentPresenceStore::LEGACY_TOPIC ], CommentPresenceStore.viewing_topics(9_901, 4)
    end

    test "renews the selected topic entry with the subscription lease" do
      CommentPresenceStore.set_topic(9_901, 4, 12)
      topic_key = CommentPresenceStore.topic_key(9_901, 4)
      original_write = Rails.cache.method(:write)
      renewed = false

      Rails.cache.stub(:write, ->(key, value, **options) {
        renewed ||= key == topic_key && value == 12 && options[:expires_in] == CommentPresenceStore::SUBSCRIPTION_TTL
        original_write.call(key, value, **options)
      }) do
        CommentPresenceStore.renew(9_901, 4)
      end

      assert renewed
    end

    test "keeps topics from other subscriptions until their own disconnect" do
      CommentPresenceStore.add(9_901, 4, subscription_id: "first")
      CommentPresenceStore.add(9_901, 4, subscription_id: "second")
      CommentPresenceStore.set_topic(9_901, 4, 12, subscription_id: "first")
      CommentPresenceStore.set_topic(9_901, 4, 13, subscription_id: "second")

      CommentPresenceStore.remove(9_901, 4, subscription_id: "second")

      assert_equal [ 4 ], CommentPresenceStore.list(9_901)
      assert_equal [ 12 ], CommentPresenceStore.viewing_topics(9_901, 4)
      CommentPresenceStore.remove(9_901, 4, subscription_id: "first")
      assert_empty CommentPresenceStore.list(9_901)
    end

    test "does not retain a crashed subscription after its lease expires" do
      CommentPresenceStore.add(9_901, 4, subscription_id: "orphan")
      CommentPresenceStore.set_topic(9_901, 4, 12, subscription_id: "orphan")

      Rails.cache.delete(CommentPresenceStore.subscription_lease_key(9_901, 4, "orphan"))

      assert_empty CommentPresenceStore.list(9_901)
      assert_empty CommentPresenceStore.subscription_ids(9_901, 4)
      assert_empty CommentPresenceStore.viewing_topics(9_901, 4)
    end

    test "fetches topics for all present users in one cache batch" do
      CommentPresenceStore.add(9_901, 4, subscription_id: "all")
      CommentPresenceStore.add(9_901, 4, subscription_id: "archived")
      CommentPresenceStore.set_topic(9_901, 4, nil, subscription_id: "all", rendered_topic_ids: [ 12 ])
      CommentPresenceStore.set_topic(9_901, 4, 12, subscription_id: "archived")

      assert_equal({ 4 => [ CommentPresenceStore::ALL_TOPICS, 12 ] }, CommentPresenceStore.viewing_topics_for(9_901, [ 4 ]))
    end

    test "serializes concurrent subscription membership updates" do
      entered = Queue.new
      release = Queue.new
      first = Thread.new do
        CommentPresenceStore.with_lock(9_901) do
          entered << true
          release.pop
        end
      end
      entered.pop

      second = Thread.new { CommentPresenceStore.add(9_901, 4, subscription_id: "second") }
      sleep(0.1)
      assert_empty CommentPresenceStore.list(9_901)

      release << true
      first.join
      second.join

      assert_equal [ 4 ], CommentPresenceStore.list(9_901)
      assert_equal [ "second" ], CommentPresenceStore.subscription_ids(9_901, 4)
    end

    test "uses a non-expiring advisory lock for PostgreSQL cache storage" do
      connection = Class.new do
        attr_reader :queries

        def initialize
          @queries = []
        end

        def adapter_name
          "PostgreSQL"
        end

        def quote(value)
          value.to_s
        end

        def select_value(query)
          queries << query
          true
        end
      end.new
      pool = Struct.new(:connection) do
        def with_connection
          yield connection
        end
      end.new(connection)

      SolidCache::Entry.stub(:connection, connection) do
        SolidCache::Entry.stub(:connection_pool, pool) do
          assert_equal :locked, CommentPresenceStore.with_lock(9_901) { :locked }
        end
      end

      advisory_key = Digest::SHA256.digest("#{CommentPresenceStore::LOCK_PURPOSE}:9901").unpack1("q>")
      assert_equal [
        "SELECT pg_advisory_lock(#{advisory_key})",
        "SELECT pg_advisory_unlock(#{advisory_key})"
      ], connection.queries
    end
  end
end
