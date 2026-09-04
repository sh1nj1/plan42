module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeUpdateService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_update_service"
    tool_description "Update an existing Creative's content, progress, or parent. Use this to:\n- Modify the description/title of a Creative\n- Mark a leaf Creative as complete (progress = 1.0)\n- Move a Creative to a different parent\n\nProgress constraints:\n- Only 1.0 (100%) is allowed — partial progress updates are not supported\n- Only leaf Creatives (with no children) can have their progress updated\n- Parent Creative progress is automatically calculated from children\n\nUse creative_retrieval_service to find the correct Creative before updating. A Creative with inherited ai_write_policy=review stores a draft in History for approval."

    tool_param :id, description: "The ID of the Creative to update.", required: true
    tool_param :description, description: "New content/title for the Creative, written in Markdown (GitHub-Flavored: headings, bold/italic, lists, links, tables, code blocks, task lists). A single newline is a line break. Replaces the whole body. If omitted, the description remains unchanged.", required: false
    tool_param :progress, description: "Set to 1.0 to mark a leaf Creative as complete. Only 1.0 is allowed; partial progress and updates on parent Creatives are rejected.", required: false
    tool_param :parent_id, description: "New parent Creative ID to move this Creative under. If omitted, nil, or 0, the parent remains unchanged.", required: false

    sig { params(id: Integer, description: T.nilable(String), progress: T.nilable(Numeric), parent_id: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
    def call(id:, description: nil, progress: nil, parent_id: nil)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: id)
      unless creative
        return { error: "Creative not found", id: id }
      end

      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on this Creative", id: id }
      end

      # Get the effective origin for updating content
      base = creative.effective_origin
      destination = Creative.find_by(id: parent_id) if parent_id.present? && parent_id != 0

      Creatives::AiWritePolicy.capture(
        creatives: review_targets(creative, base, destination, progress),
        anchor: Creatives::AiWritePolicy.agent_anchor || creative
      ) do
        perform_update(
          creative: creative, base: base, description: description,
          progress: progress, parent_id: parent_id
        )
      end
    end

    private

    def review_targets(creative, base, destination, progress)
      targets = [ creative, base, destination ]
      targets.concat(Creatives::ProgressPropagationTargets.new(base).call) if progress.present?
      targets
    end

    def perform_update(creative:, base:, description:, progress:, parent_id:)
      description_provided = prepare_description(base, description)
      updates, error = progress_updates(base, progress, creative.id)
      return error if error

      parent_updates, error = parent_updates(creative, parent_id)
      return error if error

      apply_updates(creative, base, updates, parent_updates, description_provided)
    end

    def prepare_description(base, description)
      return false unless description.present?

      # Tool-authored GFM is canonical and must reopen in the source editor so
      # structures that the rich editor cannot represent are not rewritten.
      base.content_type_input = "markdown"
      base.markdown_source = description
      base.markdown_editor = "source"
      true
    end

    def progress_updates(base, progress, creative_id)
      return [ {}, nil ] unless progress.present?

      progress_value = progress.to_f.clamp(0.0, 1.0)
      unless progress_value == 1.0
        return [ {}, { error: "Only progress of 1.0 (100%) is allowed. Partial progress updates are not supported.", id: creative_id } ]
      end
      if base.children.exists?
        return [ {}, { error: "Cannot update progress on a parent Creative. Only leaf Creatives (with no children) can be marked complete.", id: creative_id } ]
      end

      [ { progress: progress_value }, nil ]
    end

    def parent_updates(creative, parent_id)
      return [ {}, nil ] unless parent_id.present? && parent_id != 0
      return [ {}, { error: "Cannot set a Creative as its own parent", id: creative.id } ] if parent_id == creative.id

      new_parent = Creative.find_by(id: parent_id)
      return [ {}, { error: "New parent Creative not found", parent_id: parent_id } ] unless new_parent
      unless new_parent.has_permission?(Current.user, :write)
        return [ {}, { error: "No write permission on new parent Creative", parent_id: parent_id } ]
      end
      if new_parent.self_and_ancestors.include?(creative)
        return [ {}, { error: "Cannot move Creative under its own descendant", parent_id: parent_id } ]
      end

      [ { parent_id: parent_id }, nil ]
    end

    def apply_updates(creative, base, updates, parent_updates, description_provided)
      success = parent_updates.blank? || creative.update(parent_updates)
      if success && (updates.present? || description_provided)
        base.assign_attributes(updates) if updates.present?
        success = base.save
      end

      success ? success_result(creative, base) : failure_result(creative, base)
    end

    def success_result(creative, base)
      creative.reload
      base.reload
      {
        success: true,
        id: creative.id,
        description: base.description,
        parent_id: creative.parent_id,
        progress: base.progress
      }
    end

    def failure_result(creative, base)
      { error: "Failed to update Creative", details: creative.errors.full_messages + base.errors.full_messages }
    end
  end
end
end
