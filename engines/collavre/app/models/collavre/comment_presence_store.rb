module Collavre
  class CommentPresenceStore
    KEY_PREFIX = "comment_presence:"
    TOPIC_KEY_PREFIX = "comment_presence_topic:"

    def self.add(creative_id, user_id)
      ids = list(creative_id)
      unless ids.include?(user_id)
        ids << user_id
        Rails.cache.write(key(creative_id), ids)
      end
      ids
    end

    def self.remove(creative_id, user_id)
      ids = list(creative_id)
      if ids.delete(user_id)
        Rails.cache.write(key(creative_id), ids)
      end
      Rails.cache.delete(topic_key(creative_id, user_id))
      ids
    end

    def self.set_topic(creative_id, user_id, topic_id)
      topic_id ? Rails.cache.write(topic_key(creative_id, user_id), topic_id.to_i) : Rails.cache.delete(topic_key(creative_id, user_id))
    end

    def self.topic_for(creative_id, user_id)
      Rails.cache.read(topic_key(creative_id, user_id))
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

    def self.topic_key(creative_id, user_id)
      "#{TOPIC_KEY_PREFIX}#{creative_id}:#{user_id}"
    end
  end
end
