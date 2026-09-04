# frozen_string_literal: true

module Collavre
  module Creatives
    class HistoricalSnapshotAuthorization
      def self.initial_attributes(creative, before, position)
        {
          before: before,
          position: position,
          conflict: { "before_permission" => metadata_for(creative, before) }
        }
      end

      def self.after_attributes(change, creative, after)
        permission = metadata_for(creative, after)
        { after: after, conflict: change.conflict.merge("after_permission" => permission) }
      end

      def self.metadata_for(creative, snapshot)
        effective = creative.effective_origin(Set.new)
        path_ids = if effective != creative
                     hierarchy_path(effective.id)
        else
                     [ creative.id, *hierarchy_path(snapshot["parent_id"]) ]
        end
        { "owner_id" => effective.user_id, "path_ids" => path_ids }
      end

      def self.hierarchy_path(descendant_id)
        return [] unless descendant_id

        CreativeHierarchy.where(descendant_id: descendant_id).order(:generations).pluck(:ancestor_id)
      end
      private_class_method :metadata_for, :hierarchy_path

      def initialize(user:)
        @user_id = user&.id
        @shares_by_key = {}
        @loaded_path_ids = Set.new
      end

      def snapshots_visible?(changes, state)
        changes.all? do |change|
          snapshot = change.public_send(state)
          snapshot.empty? || snapshot_visible?(change, state)
        end
      end

      private

      def snapshot_visible?(change, state)
        permission = change.conflict["#{state}_permission"]
        return change.change_set.user_id == @user_id unless permission
        return true if permission["owner_id"] == @user_id

        permission_granted?(permission.fetch("path_ids"))
      end

      def permission_granted?(path_ids)
        load_shares(path_ids)
        user_share = nearest_share(path_ids, @user_id) if @user_id
        return grants_read?(user_share) if user_share

        grants_read?(nearest_share(path_ids, nil))
      end

      def load_shares(path_ids)
        missing_ids = path_ids - @loaded_path_ids.to_a
        return if missing_ids.empty?

        user_ids = @user_id ? [ @user_id, nil ] : [ nil ]
        CreativeShare.where(creative_id: missing_ids, user_id: user_ids).find_each do |share|
          @shares_by_key[[ share.creative_id, share.user_id ]] = share
        end
        @loaded_path_ids.merge(missing_ids)
      end

      def nearest_share(path_ids, user_id)
        path_ids.each do |creative_id|
          share = @shares_by_key[[ creative_id, user_id ]]
          return share if share
        end
        nil
      end

      def grants_read?(share)
        share && CreativeShare.permissions.fetch(share.permission) >= CreativeShare.permissions.fetch("read")
      end
    end
  end
end
