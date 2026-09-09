# frozen_string_literal: true

module Collavre
  class CreativeTreeInvalidationJob < ApplicationJob
    queue_as :default

    def perform(creative_ids)
      ids = Array(creative_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      return if ids.empty?

      candidate_users(ids).find_each do |user|
        next if Creatives::PermissionFilter.new(user: user).readable_ids(ids).empty?

        Turbo::StreamsChannel.broadcast_action_to(
          [ user, :creative_tree ],
          action: :invalidate_creative_tree,
          target: "creatives"
        )
      end
    end

    private

    def candidate_users(ids)
      cache_scope = CreativeSharesCache.where(creative_id: ids)
      return User.all if cache_scope.where(user_id: nil).where.not(permission: :no_access).exists?

      user_ids = Creative.unscoped.where(id: ids).pluck(:user_id)
      user_ids.concat(cache_scope.where.not(user_id: nil).pluck(:user_id))
      User.where(id: user_ids.compact.uniq)
    end
  end
end
