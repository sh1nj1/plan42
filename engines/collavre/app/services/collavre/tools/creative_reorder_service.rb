module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeReorderService
    extend T::Sig
    extend ToolMeta

    # Raised inside the parent lock when the resulting order differs from the
    # submitted one, rolling the reorder back.
    class ConcurrentChangeError < StandardError; end

    tool_name "creative_reorder_service"
    tool_description "Reorder the direct children of a Creative. Pass the complete list of the parent's child ids in the desired order; the children are resequenced to exactly that order. Use creative_retrieval_service with level 2 (level 1 returns only the parent itself) to read the current children first. The list must contain every direct child exactly once — missing, extra, or duplicate ids are rejected and nothing changes. Requires write permission on the parent and every child. For a linked Creative, its origin's children are reordered. A Creative with inherited ai_write_policy=review stores a draft in History for approval."

    tool_param :parent_id, description: "ID of the Creative whose direct children are reordered.", required: true
    tool_param :ordered_ids, description: "Comma-separated ids of ALL direct children in the desired order, e.g. \"12,45,78\". A JSON array of ids also works.", required: true

    sig { params(parent_id: Integer, ordered_ids: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
    def call(parent_id:, ordered_ids:)
      raise I18n.t("collavre.tools.creative_reorder.errors.current_user_required") unless Current.user

      requested = Creative.find_by(id: parent_id)
      return error(:creative_not_found, parent_id: parent_id) unless requested

      # A linked Creative shows its origin's children (linked_children), so
      # validate and reorder against the origin the agent actually sees.
      parent = requested.effective_origin
      return error(:write_permission, parent_id: parent_id) unless parent.has_permission?(Current.user, :write)

      ids = parse_ids(ordered_ids)
      return error(:invalid_ids, parent_id: parent_id) if ids.nil?

      reorder_children(requested, parent, ids)
    rescue ::Creatives::Reorderer::PermissionError
      error(:child_write_permission, parent_id: parent_id)
    rescue ConcurrentChangeError
      error(:concurrent_change, parent_id: parent_id)
    rescue ::Creatives::Reorderer::Error => e
      Rails.logger.warn("[creative_reorder] parent=#{parent_id} #{e.class}: #{e.message}")
      error(:reorder_failed, parent_id: parent_id)
    end

    private

    def reorder_children(requested, parent, ids)
      children = parent.children.to_a
      # Keep the requested link as a review target: its placement can inherit
      # ai_write_policy=review even when the origin is auto.
      Creatives::AiWritePolicy.capture(
        creatives: [ requested, parent, *children ],
        anchor: Creatives::AiWritePolicy.agent_anchor || requested
      ) do
        # Snapshot, validate and reorder under one lock: the parent row plus
        # every current/listed child row, so a concurrent move of one of them
        # waits for this transaction instead of being silently overwritten.
        parent.with_lock { locked_reorder(parent, ids) }
      end
    end

    def locked_reorder(parent, ids)
      children = Creative.where(parent_id: parent.id).or(Creative.where(id: ids)).order(:id).lock.to_a
                         .select { |creative| creative.parent_id == parent.id }
      # Authorize every child before comparing lists so missing_ids never
      # reveals a child the caller cannot write (or even see).
      return error(:child_write_permission, parent_id: parent.id) unless children_writable?(children)

      validation_error = validate_complete_list(parent, children.map(&:id), ids)
      return validation_error if validation_error

      ::Creatives::Reorderer.new(user: Current.user).reorder_multiple(
        dragged_ids: ids, target_id: parent.id, direction: "child"
      )
      result_ids = parent.children.order(:sequence).pluck(:id)
      raise ConcurrentChangeError unless result_ids == ids

      { success: true, parent_id: parent.id, ordered_ids: result_ids }
    end

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
      return false unless allowed.size == child_ids.size
      return true unless Current.authoritative_permissions

      # Approval replay: the batch filter reads CreativeSharesCache, which can
      # still grant a child whose share was revoked during the approval delay.
      children.all? { |child| currently_writable?(child) }
    end

    # current_allowed? resolves a linked shell to its origin, so a shell's own
    # placement grant is rechecked separately.
    def currently_writable?(child)
      checker = Collavre::Creatives::PermissionChecker
      return false unless checker.current_allowed?(child.id, Current.user, :write)

      child.origin_id.nil? || checker.current_placement_allowed?(child.id, Current.user, :write)
    end

    def validate_complete_list(parent, child_ids, ids)
      return error(:duplicate_ids, parent_id: parent.id) if ids.uniq.size != ids.size

      missing = child_ids - ids
      extra = ids - child_ids
      return nil if missing.empty? && extra.empty?

      error(:incomplete_list, parent_id: parent.id, missing_ids: missing, unknown_ids: extra)
    end

    def error(key, **attributes)
      { error: I18n.t("collavre.tools.creative_reorder.errors.#{key}"), **attributes }
    end
  end
end
end
