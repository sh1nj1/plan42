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
      raise "Current.user is required" unless Current.user

      parent = Creative.find_by(id: parent_id)
      return { error: "Creative not found", parent_id: parent_id } unless parent
      return { error: "No write permission on this Creative", parent_id: parent_id } unless parent.has_permission?(Current.user, :write)

      ids = parse_ids(ordered_ids)
      return { error: "ordered_ids must be a list of integer ids", parent_id: parent_id } if ids.nil?

      error = validate_complete_list(parent, ids)
      return error if error

      children = parent.children.to_a
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
      { error: "No write permission on one or more child Creatives", parent_id: parent_id }
    rescue ::Creatives::Reorderer::Error => e
      { error: "Failed to reorder: #{e.message}", parent_id: parent_id }
    end

    private

    def parse_ids(value)
      raw = value.is_a?(Array) ? value : value.to_s.split(",")
      ids = raw.map { |id| id.to_s.strip }.reject(&:empty?)
      return nil if ids.empty? || ids.any? { |id| id !~ /\A\d+\z/ }

      ids.map(&:to_i)
    end

    def validate_complete_list(parent, ids)
      return { error: "ordered_ids contains duplicates", parent_id: parent.id } if ids.uniq.size != ids.size

      child_ids = parent.children.pluck(:id)
      missing = child_ids - ids
      extra = ids - child_ids
      return nil if missing.empty? && extra.empty?

      { error: "ordered_ids must list every direct child exactly once", parent_id: parent.id, missing_ids: missing, unknown_ids: extra }
    end
  end
end
end
