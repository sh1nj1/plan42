# frozen_string_literal: true

module Collavre
  module Workflow
    class Resolver
      MAX_RULES = 200

      def initialize(context)
        @context = context
      end

      def rules
        return @rules if defined?(@rules)

        parsed = rule_creatives.filter_map { |creative| Rule.from(creative) }
        warn_discarded(parsed.length - MAX_RULES) if parsed.length > MAX_RULES
        @rules = parsed.first(MAX_RULES)
      end

      def workflow_creative_ids
        return @workflow_creative_ids if defined?(@workflow_creative_ids)

        @workflow_creative_ids = workflow_creatives.map(&:id)
      end

      private

      def workflow_creatives
        return @workflow_creatives if defined?(@workflow_creatives)

        ids = active_context_ids
        indexed = Creative.active.where(id: ids).index_by(&:id)
        Creatives::OriginChainPreloader.preload(indexed.values)
        @workflow_creatives = ids.filter_map { |id| indexed[id]&.effective_origin(Set.new) }
          .select { |creative| creative.archived_at.nil? && creative.workflow? }
          .reject { |creative| @excluded_context_ids.include?(creative.id) }
          .uniq(&:id)
      end

      def active_context_ids
        creative = Creative.find_by(id: @context.dig("creative", "id"))
        return [] unless creative

        origin = creative.effective_origin(Set.new)
        @excluded_context_ids = [ creative.id, origin.id ]
        origin.effective_context_ids - origin.effective_disabled_context_ids - @excluded_context_ids
      end

      def rule_creatives
        ids = workflow_creative_ids
        return [] if ids.empty?

        grouped = Creative.active
          .where(parent_id: ids)
          .order(:parent_id, :sequence, :id)
          .group_by(&:parent_id)
        ids.flat_map { |id| grouped.fetch(id, []) }
      end

      def warn_discarded(count)
        Rails.logger.warn("[Workflow::Resolver] Discarded #{count} valid rules above the #{MAX_RULES}-rule limit")
      end
    end
  end
end
