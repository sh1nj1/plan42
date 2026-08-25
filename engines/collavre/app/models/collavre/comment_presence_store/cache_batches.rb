# frozen_string_literal: true

module Collavre
  class CommentPresenceStore
    module CacheBatches
      def active_subscriptions_for_creatives(ids, user_id, subscription_keys, subscriptions)
        lease_keys = subscription_lease_keys(ids, user_id, subscription_keys, subscriptions)
        leases = Rails.cache.read_multi(*lease_keys.values)
        ids.to_h do |creative_id|
          subscription_ids = Array(subscriptions[subscription_keys.fetch(creative_id)])
          active_ids = subscription_ids.select { |id| leases[lease_keys.fetch([ creative_id, id ])] }
          [ creative_id, active_ids ]
        end
      end

      def subscription_lease_keys(ids, user_id, subscription_keys, subscriptions)
        ids.flat_map do |creative_id|
          Array(subscriptions[subscription_keys.fetch(creative_id)]).map do |subscription_id|
            [ [ creative_id, subscription_id ], subscription_lease_key(creative_id, user_id, subscription_id) ]
          end
        end.to_h
      end

      def viewing_topics_from_subscriptions(subscriptions_by_creative_id, user_id)
        topic_keys = subscriptions_by_creative_id.to_h do |creative_id, subscription_ids|
          [ creative_id, subscription_ids.map { |id| topic_key(creative_id, user_id, id) } ]
        end
        cached_topics = Rails.cache.read_multi(*topic_keys.values.flatten)
        topic_keys.transform_values { |keys| keys.flat_map { |key| Array(cached_topics[key]) }.compact.uniq }
      end

      def cached_user_ids(ids)
        cached = Rails.cache.read_multi(*ids.map { |creative_id| key(creative_id) })
        ids.to_h { |creative_id| [ creative_id, cached[key(creative_id)] || [] ] }
      end

      def cached_subscriptions_for(user_ids_by_creative_id)
        keys = subscription_keys_by_pair(user_ids_by_creative_id)
        Rails.cache.read_multi(*keys.values)
      end

      def cached_subscription_leases(user_ids_by_creative_id, subscriptions)
        keys = subscription_keys_by_pair(user_ids_by_creative_id)
        lease_keys = keys.flat_map do |(creative_id, user_id), subscription_key|
          Array(subscriptions[subscription_key]).map { |id| subscription_lease_key(creative_id, user_id, id) }
        end
        Rails.cache.read_multi(*lease_keys)
      end

      def present_users_from_cache(user_ids_by_creative_id, subscriptions, leases)
        user_ids_by_creative_id.to_h do |creative_id, user_ids|
          users = user_ids.select { |user_id| active_subscription_ids_from_cache(creative_id, user_id, subscriptions, leases).any? }
          [ creative_id, users ]
        end
      end

      def subscription_keys_by_pair(user_ids_by_creative_id)
        user_ids_by_creative_id.flat_map do |creative_id, user_ids|
          user_ids.map { |user_id| [ [ creative_id, user_id ], subscriptions_key(creative_id, user_id) ] }
        end.to_h
      end
    end
  end
end
