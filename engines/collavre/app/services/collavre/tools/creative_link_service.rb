require "sorbet-runtime"
require "rails_mcp_engine"

module Collavre
  module Tools
    class CreativeLinkService
      extend T::Sig
      extend ToolMeta

      tool_name "creative_link_service"
      tool_description "Link a list of Creatives below a parent. New links are appended in input order; existing links to the same origin are reused in their current positions. Requires read on sources and write on the destination. Review policy stores a draft for approval."
      tool_param :parent_id, description: "Destination parent Creative ID.", required: true
      tool_param :creative_ids, description: "Array of source Creative IDs.", required: true

      sig { params(parent_id: Integer, creative_ids: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def call(parent_id:, creative_ids:)
        previous_change_set = Current.change_set
        previous_history_context = Current.creative_history_context
        raise I18n.t("collavre.tools.creative_links.errors.current_user_required") unless Current.user

        ids = CreativeLinkService.valid_ids(creative_ids)
        return error(:invalid_ids) unless ids

        requested = Creative.find_by(id: parent_id)
        return error(:not_found) unless requested

        parent = requested.effective_origin
        sources = Creative.where(id: ids).index_by(&:id)
        return error(:not_found) unless sources.size == ids.size

        Creatives::AiWritePolicy.capture(creatives: [ requested, parent, *parent.children, *Creatives::ProgressPropagationTargets.new(parent).call ], anchor: requested) do
          parent.with_lock { link_all(requested, parent, ids.map { |id| sources.fetch(id) }) }
        end
      rescue Creatives::Reorderer::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
        Current.change_set = previous_change_set&.reload
        Current.creative_history_context = previous_history_context
        error(:failed)
      end

      def self.valid_ids(value)
        return unless value.is_a?(Array) && value.present? && value.all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }

        ids = value.map(&:to_i)
        ids if ids.uniq.size == ids.size
      end

      private

      def link_all(requested, parent, sources)
        filter = Creatives::PermissionFilter.new(user: Current.user)
        raise Creatives::Reorderer::PermissionError unless filter.all_readable?([ requested.id, parent.id ], min_permission: :write)
        raise Creatives::Reorderer::PermissionError unless filter.all_readable?(sources.map(&:id))

        reorderer = Creatives::Reorderer.new(user: Current.user)
        sources.each { |source| reorderer.validate_link!(origin: source.effective_origin, parent: parent) }
        links = sources.map do |source|
          origin = source.effective_origin
          link = parent.children.find_by(origin_id: origin.id) ||
                 reorderer.link_drop(dragged_id: source.id, target_id: parent.id, direction: "child").new_creative
          { id: link.id, origin_id: link.origin_id, parent_id: link.parent_id }
        end
        { success: true, parent_id: parent.id, links: links }
      end

      def error(key)
        { error: I18n.t("collavre.tools.creative_links.errors.#{key}") }
      end
    end
  end
end
