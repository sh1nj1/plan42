# frozen_string_literal: true

module Collavre
  module Kollavy
    # Sharing one agent across Inboxes must not combine their data. During a
    # Kollavy turn, permissions are intersected with the task's creative tree.
    # The task is server-owned context, never a model-supplied tool argument.
    # Calls as Kollavy without a matching turn fail closed.
    class AccessScope
      def self.restricted?(user = Current.user)
        user&.email == EMAIL && Current.user == user
      end

      def self.filter(ids, user = Current.user)
        return ids unless restricted?(user)

        root = anchor(user)
        return [] unless root

        tree = CreativeHierarchy.where(ancestor_id: root.id).select(:descendant_id)
        candidates = Creative.where(id: ids).where(id: tree).pluck(:id)
        effective = Creatives::EffectiveCreativeResolution.effective_creative_ids(candidates)
        allowed_origins = Creative.where(id: effective.values).where(id: tree).pluck(:id).to_set
        candidates.select { |id| allowed_origins.include?(effective[id]) }
      end

      def self.allowed?(creative, user)
        !restricted?(user) || filter([ creative.id ], user).include?(creative.id)
      end

      def self.context_id(context, user)
        filter(Array(context.dig("creative", "id")), user).first
      end

      def self.roots
        Creative.where(id: filter([ anchor(Current.user)&.id ].compact))
          .select { |creative| creative.has_permission?(Current.user, :read) }
      end

      def self.anchor(user)
        task = Current.agent_turn&.dig(:task)
        return unless task&.agent_id == user.id && task.creative_id

        Creative.find_by(id: task.creative_id)&.effective_origin
      end
      private_class_method :anchor
    end
  end
end
