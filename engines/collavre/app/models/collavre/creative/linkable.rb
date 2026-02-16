module Collavre
  class Creative < ApplicationRecord
    module Linkable
      extend ActiveSupport::Concern

      included do
        belongs_to :origin, class_name: "Collavre::Creative", optional: true
        has_many :linked_creatives, class_name: "Collavre::Creative", foreign_key: :origin_id, dependent: :destroy

        validate :origin_cannot_be_self
        before_validation :redirect_parent_to_origin
      end

      # Returns the effective attribute for linked creatives
      def effective_attribute(attr, visited_ids = Set.new)
        return self[attr] if origin_id.nil? || attr.to_s == "parent_id"
        return self[attr] if visited_ids.include?(id)

        visited_ids.add(id)
        origin.effective_attribute(attr, visited_ids)
      end

      def effective_origin(visited_ids = Set.new)
        return self if origin_id.nil?
        return self if visited_ids.include?(id)

        visited_ids.add(id)
        origin.effective_origin(visited_ids)
      end

      def linked_children
        origin_id.nil? ? children_with_permission(Collavre.current_user, :read) : origin&.children_with_permission(Collavre.current_user, :read) || []
      end

      def progress
        effective_attribute(:progress, Set.new)
      end

      def user
        target = effective_origin(Set.new)
        return super if target == self

        target.user
      end

      # 공유 대상 사용자를 위해 Linked Creative를 생성합니다.
      def create_linked_creative_for_user(user)
        original = effective_origin(Set.new)
        return if original.user_id == user.id
        ancestor_ids = original.ancestors.pluck(:id)
        has_ancestor_share = CreativeShare.where(creative_id: ancestor_ids, user_id: user.id)
                                          .where.not(permission: :no_access)
                                          .exists?
        has_owning_ancestors = Creative.where(id: ancestor_ids, user_id: user.id)
                                            .exists?
        return if has_ancestor_share or has_owning_ancestors
        Creative.find_or_create_by!(origin_id: original.id, user_id: user.id) do |c|
          c.parent_id = nil
        end
      end

      private

      def redirect_parent_to_origin
        if parent&.origin_id.present?
          self.parent = parent.origin
        end
      end

      def origin_cannot_be_self
        if origin_id.present? && origin_id == id
          errors.add(:origin_id, "cannot be the same as id")
        end
      end
    end
  end
end
