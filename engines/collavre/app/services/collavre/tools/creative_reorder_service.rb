module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeReorderService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_reorder_service"
    tool_description "Reorder the direct children of a Creative. Pass the complete list of the parent's child ids in the desired order; the children are resequenced to exactly that order. Use creative_retrieval_service (level 1) to read the current children first. The list must contain every direct child exactly once — missing, extra, or duplicate ids are rejected and nothing changes. Requires write permission on the parent and every child. A Creative with inherited ai_write_policy=review stores a draft in History for approval."

    tool_param :parent_id, description: "ID of the Creative whose direct children are reordered.", required: true
    tool_param :ordered_ids, description: "Comma-separated ids of ALL direct children in the desired order, e.g. \"12,45,78\". A JSON array of ids also works.", required: true

    sig { params(parent_id: Integer, ordered_ids: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
    def call(parent_id:, ordered_ids:)
      raise I18n.t("collavre.tools.creative_reorder.errors.current_user_required") unless Current.user

      parent = Creative.find_by(id: parent_id)
      return error(:creative_not_found, parent_id: parent_id) unless parent
      return error(:write_permission, parent_id: parent_id) unless parent.has_permission?(Current.user, :write)

      ids = parse_ids(ordered_ids)
      return error(:invalid_ids, parent_id: parent_id) if ids.nil?

      children = parent.children.to_a
      # Authorize every child before comparing lists so missing_ids never
      # reveals a child the caller cannot write (or even see).
      return error(:child_write_permission, parent_id: parent_id) unless children_writable?(children)

      validation_error = validate_complete_list(parent, children.map(&:id), ids)
      return validation_error if validation_error

      Creatives::AiWritePolicy.capture(
        creatives: [ parent, *children ],
        anchor: Creatives::AiWritePolicy.agent_anchor || parent
      ) do
        ::Creatives::Reorderer.new(user: Current.user).reorder_multiple(
          dragged_ids: ids, target_id: parent.id, direction: "child"
        )
        { success: true, parent_id: parent.id, ordered_ids: parent.children.order(:sequence).pluck(:id) }
      end
    rescue ::Creatives::Reorderer::PermissionError
      error(:child_write_permission, parent_id: parent_id)
    rescue ::Creatives::Reorderer::Error => e
      error(:reorder_failed, parent_id: parent_id, message: e.message)
    end

    private

    def parse_ids(value)
      raw = value.is_a?(Array) ? value : value.to_s.split(",")
      ids = raw.map { |id| id.to_s.strip }.reject(&:empty?)
      return nil if ids.empty? || ids.any? { |id| id !~ /\A\d+\z/ }

      ids.map(&:to_i)
    end

    def children_writable?(children)
      return true if children.empty?

      child_ids = children.map(&:id)
      allowed = Collavre::Creatives::PermissionFilter.new(user: Current.user).readable_ids(child_ids, min_permission: :write)
      allowed.size == child_ids.size
    end

    def validate_complete_list(parent, child_ids, ids)
      return error(:duplicate_ids, parent_id: parent.id) if ids.uniq.size != ids.size

      missing = child_ids - ids
      extra = ids - child_ids
      return nil if missing.empty? && extra.empty?

      error(:incomplete_list, parent_id: parent.id, missing_ids: missing, unknown_ids: extra)
    end

    def error(key, message: nil, **attributes)
      { error: I18n.t("collavre.tools.creative_reorder.errors.#{key}", message: message), **attributes }
    end
  end
end
end
