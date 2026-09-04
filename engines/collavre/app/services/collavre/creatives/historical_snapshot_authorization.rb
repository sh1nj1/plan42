# frozen_string_literal: true

module Collavre
  module Creatives
    class HistoricalSnapshotAuthorization
      PERMISSION_KEYS = %w[before_permission after_permission].freeze

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

      def self.merge_actual_metadata(actual, captured)
        captured.merge(actual.slice(*PERMISSION_KEYS))
      end

      def self.metadata_for(creative, snapshot)
        effective = creative.effective_origin(Set.new)
        placement = permission_requirement(creative.user_id, creative.id, snapshot["parent_id"])
        requirements = if effective != creative
                         [ permission_requirement(effective.user_id, effective.id, effective.parent_id), placement ]
        else
                         [ placement ]
        end
        { "requirements" => requirements }
      end

      def self.permission_requirement(owner_id, creative_id, parent_id)
        { "owner_id" => owner_id, "path_ids" => [ creative_id, *hierarchy_path(parent_id) ] }
      end

      def self.hierarchy_path(descendant_id)
        return [] unless descendant_id

        CreativeHierarchy.where(descendant_id: descendant_id).order(:generations).pluck(:ancestor_id)
      end
      private_class_method :metadata_for, :permission_requirement, :hierarchy_path

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

        requirements_for(permission).all? do |requirement|
          (@user_id && requirement["owner_id"] == @user_id) ||
            permission_granted?(requirement.fetch("path_ids"))
        end
      end

      def requirements_for(permission)
        permission["requirements"] || [ permission ]
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
