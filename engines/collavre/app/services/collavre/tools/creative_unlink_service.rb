require "sorbet-runtime"
require "rails_mcp_engine"

module Collavre
  module Tools
    class CreativeUnlinkService
      extend T::Sig
      extend ToolMeta

      tool_name "creative_unlink_service"
      tool_description "Remove linked Creative shells by ID, preserving their origins and other links. Rejects ordinary Creative IDs. All removals are atomic. Review policy stores a draft for approval."
      tool_param :linked_creative_ids, description: "Array of linked Creative shell IDs to remove.", required: true

      sig { params(linked_creative_ids: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def call(linked_creative_ids:)
        previous_change_set = Current.change_set
        previous_history_context = Current.creative_history_context
        raise I18n.t("collavre.tools.creative_links.errors.current_user_required") unless Current.user

        ids = CreativeLinkService.valid_ids(linked_creative_ids)
        return error(:invalid_ids) unless ids

        links = Creative.where(id: ids).to_a
        return error(:not_found) unless links.size == ids.size

        Creatives::AiWritePolicy.capture(creatives: links + links.flat_map { |link| Creatives::ProgressPropagationTargets.new(link).call }, anchor: links.first.parent || links.first) do
          Creative.transaction { unlink_all(ids) }
        end
      rescue Creatives::Reorderer::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
        Current.change_set = previous_change_set&.reload
        Current.creative_history_context = previous_history_context
        error(:failed)
      end

      private

      def unlink_all(ids)
        links = Creative.where(id: ids).order(:id).lock.to_a
        raise Creatives::Reorderer::Error unless links.size == ids.size
        raise Creatives::Reorderer::Error unless links.all? { |link| link.origin_id.present? && link.destroyable_by?(Current.user) }

        selected = links.index_by(&:id)
        links.sort_by { |link| -selected_origin_depth(link, selected) }.each { |link| link.reload.destroy! }
        { success: true, unlinked_ids: ids }
      end

      def selected_origin_depth(link, selected)
        visited = Set.new
        while link && visited.add?(link.id)
          link = selected[link.origin_id]
        end
        visited.size
      end

      def error(key)
        { error: I18n.t("collavre.tools.creative_links.errors.#{key}") }
      end
    end
  end
end
