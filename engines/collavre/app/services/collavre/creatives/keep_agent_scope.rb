module Collavre
  module Creatives
    # Apply owner/user/public precedence in SQL before the picker result limit.
    class KeepAgentScope
      def initialize(creative)
        @base = EffectiveCreativeResolution.effective_creative(creative)
      end

      def apply(scope)
        scope = selectable_names(scope)
        entries = CreativeSharesCache.where(creative_id: @base.id)
        granted = entries.where(permission: [ :feedback, :write, :admin ]).where.not(user_id: nil).select(:user_id)
        eligible = scope.where(id: @base.user_id).or(scope.where(id: granted))
        return eligible unless entries.exists?(user_id: nil, permission: [ :feedback, :write, :admin ])

        eligible.or(scope.where.not(id: entries.where.not(user_id: nil).select(:user_id)))
      end

      private

      def selectable_names(scope)
        duplicates = User.ai_agents.where.not(name: nil).group("LOWER(name)").having("COUNT(*) > 1").select("LOWER(name)")
        scope.where.not(name: [ nil, "" ])
             .where.not("LOWER(name) IN (?)", duplicates)
             .where.not("name LIKE ?", "%:%")
      end
    end
  end
end
