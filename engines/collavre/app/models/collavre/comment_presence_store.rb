module Collavre
  class CommentPresenceStore
    KEY_PREFIX = "comment_presence:"
    TOPIC_KEY_PREFIX = "comment_presence_topic:"
    SUBSCRIPTIONS_KEY_PREFIX = "comment_presence_subscriptions:"
    LOCK_KEY_PREFIX = "comment_presence_lock:"
    ALL_TOPICS = "all"
    LEGACY_SUBSCRIPTION_ID = "legacy"
    LOCK_TTL = 2.seconds

    def self.add(creative_id, user_id, subscription_id: LEGACY_SUBSCRIPTION_ID)
      with_lock(creative_id) do
        subscriptions = subscription_ids(creative_id, user_id)
        unless subscriptions.include?(subscription_id)
          subscriptions << subscription_id
          Rails.cache.write(subscriptions_key(creative_id, user_id), subscriptions)
        end

        ids = list(creative_id)
        unless ids.include?(user_id)
          ids << user_id
          Rails.cache.write(key(creative_id), ids)
        end
        ids
      end
    end

    def self.remove(creative_id, user_id, subscription_id: LEGACY_SUBSCRIPTION_ID)
      with_lock(creative_id) do
        subscriptions = subscription_ids(creative_id, user_id)
        subscriptions.delete(subscription_id)
        Rails.cache.write(subscriptions_key(creative_id, user_id), subscriptions) if subscriptions.any?
        Rails.cache.delete(subscriptions_key(creative_id, user_id)) if subscriptions.empty?
        Rails.cache.delete(topic_key(creative_id, user_id, subscription_id))

        next list(creative_id) if subscriptions.any?

        ids = list(creative_id)
        if ids.delete(user_id)
          Rails.cache.write(key(creative_id), ids)
        end
        ids
      end
    end

    def self.set_topic(creative_id, user_id, topic_id, subscription_id: LEGACY_SUBSCRIPTION_ID)
      Rails.cache.write(topic_key(creative_id, user_id, subscription_id), topic_id ? topic_id.to_i : ALL_TOPICS)
    end

    def self.topic_for(creative_id, user_id)
      value = viewing_topics(creative_id, user_id).find { |topic| topic != ALL_TOPICS }
      value == ALL_TOPICS ? nil : value
    end

    def self.viewing_all_topics?(creative_id, user_id)
      viewing_topics(creative_id, user_id).include?(ALL_TOPICS)
    end

    # A user can have several open chat subscriptions. Keep every subscription's
    # selected topic so closing one tab cannot erase another tab's suppression.
    def self.viewing_topics(creative_id, user_id)
      ids = subscription_ids(creative_id, user_id)
      ids << LEGACY_SUBSCRIPTION_ID if ids.empty? && Rails.cache.exist?(topic_key(creative_id, user_id))
      Rails.cache.read_multi(*ids.map { |subscription_id| topic_key(creative_id, user_id, subscription_id) }).values.compact.uniq
    end

    # Fetch selected topics for all present recipients in cache batches. Badge
    # fanout has one creative and many recipients, so calling #viewing_topics
    # for each one would otherwise turn the cache work back into an N+1.
    def self.viewing_topics_for(creative_id, user_ids)
      ids = Array(user_ids).uniq
      return {} if ids.empty?

      subscription_keys_by_user_id = ids.to_h { |user_id| [ user_id, subscriptions_key(creative_id, user_id) ] }
      cached_subscriptions = Rails.cache.read_multi(*subscription_keys_by_user_id.values)
      topic_keys_by_user_id = ids.to_h do |user_id|
        subscription_ids = cached_subscriptions.fetch(subscription_keys_by_user_id.fetch(user_id), [])
        subscription_ids = [ LEGACY_SUBSCRIPTION_ID ] if subscription_ids.empty?
        [ user_id, subscription_ids.map { |subscription_id| topic_key(creative_id, user_id, subscription_id) } ]
      end
      cached_topics = Rails.cache.read_multi(*topic_keys_by_user_id.values.flatten)

      topic_keys_by_user_id.transform_values do |topic_keys|
        topic_keys.filter_map { |topic_key| cached_topics[topic_key] }.uniq
      end
    end

    def self.list(creative_id)
      Rails.cache.read(key(creative_id)) || []
    end

    # Presence for many creatives in one round trip.
    #
    # Rails.cache is :solid_cache_store in production — the app's own database —
    # so a per-node `list` while rendering a creative tree is a SELECT per node.
    # The LocalCache middleware that fronts Rails.cache for the duration of a
    # request does not help: it memoizes per *key*, and presence is keyed by
    # creative, so a tree of N nodes asks for N different keys. Repeated reads of
    # the single completion-mark setting are memoized separately by the request's
    # view context.
    #
    # Returns an entry for every id asked for, empty when nobody is present, so
    # callers never have to distinguish "absent from the cache" from "nobody
    # there".
    def self.list_many(creative_ids)
      ids = Array(creative_ids).uniq
      return {} if ids.empty?

      ids_by_cache_key = ids.index_by { |creative_id| key(creative_id) }
      cached = Rails.cache.read_multi(*ids_by_cache_key.keys)

      ids_by_cache_key.each_with_object({}) do |(cache_key, creative_id), result|
        result[creative_id] = cached[cache_key] || []
      end
    end

    def self.key(creative_id)
      "#{KEY_PREFIX}#{creative_id}"
    end

    def self.topic_key(creative_id, user_id, subscription_id = LEGACY_SUBSCRIPTION_ID)
      "#{TOPIC_KEY_PREFIX}#{creative_id}:#{user_id}:#{subscription_id}"
    end

    def self.subscriptions_key(creative_id, user_id)
      "#{SUBSCRIPTIONS_KEY_PREFIX}#{creative_id}:#{user_id}"
    end

    def self.lock_key(creative_id)
      "#{LOCK_KEY_PREFIX}#{creative_id}"
    end

    def self.subscription_ids(creative_id, user_id)
      Rails.cache.read(subscriptions_key(creative_id, user_id)) || []
    end

    # Membership changes update two cache entries, so serialize them across
    # Action Cable processes. The expiring lock recovers automatically if a
    # process dies while holding it.
    def self.with_lock(creative_id, &block)
      key = lock_key(creative_id)
      token = SecureRandom.uuid
      until Rails.cache.write(key, token, unless_exist: true, expires_in: LOCK_TTL)
        sleep(0.05)
      end

      block.call
    ensure
      release_lock(key, token) if key && token
    end

    # A lock may expire while its holder is paused. Only its owner may release
    # it, so an expired holder cannot delete the lease acquired by its successor.
    def self.release_lock(key, token)
      if defined?(SolidCache::Store) && Rails.cache.is_a?(SolidCache::Store)
        release_solid_cache_lock(key, token)
      elsif Rails.cache.read(key) == token
        Rails.cache.delete(key)
      end
    end

    def self.release_solid_cache_lock(key, token)
      value = SolidCache::Entry.read(key)
      entry = Rails.cache.send(:deserialize_entry, value)
      return unless entry&.value == token

      SolidCache::Entry.where(
        key_hash: Digest::SHA256.digest(key).unpack1("q>"),
        value: value
      ).delete_all
    end
  end
end
