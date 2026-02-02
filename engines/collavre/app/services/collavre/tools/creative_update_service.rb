module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeUpdateService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_update_service"
    tool_description "Update an existing Creative's content, progress, or parent. Use this to:\n- Modify the description/title of a Creative\n- Update progress (0.0 to 1.0, where 1.0 = complete)\n- Move a Creative to a different parent\n\nNote: Setting progress to 1.0 on a parent will also complete all descendants."

    tool_param :id, description: "The ID of the Creative to update.", required: true
    tool_param :description, description: "New content/title for the Creative. Accepts HTML format. If omitted, description remains unchanged.", required: false
    tool_param :progress, description: "New progress value (0.0 to 1.0). Setting to 1.0 marks as complete.", required: false
    tool_param :parent_id, description: "New parent Creative ID to move this Creative under. Use null/0 to make it a root Creative.", required: false

    sig { params(id: Integer, description: T.nilable(String), progress: T.nilable(Float), parent_id: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
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
      previous_progress = base.progress

      updates = {}
      parent_updates = {}

      # Handle description update
      if description.present?
        updates[:description] = normalize_description(description)
      end

      # Handle progress update
      if progress.present?
        updates[:progress] = progress.to_f.clamp(0.0, 1.0)
      end

      # Handle parent change (on the creative itself, not base)
      if parent_id.present? || parent_id == 0
        new_parent_id = parent_id == 0 ? nil : parent_id

        if new_parent_id.present?
          new_parent = Creative.find_by(id: new_parent_id)
          unless new_parent
            return { error: "New parent Creative not found", parent_id: new_parent_id }
          end
          unless new_parent.has_permission?(Current.user, :write)
            return { error: "No write permission on new parent Creative", parent_id: new_parent_id }
          end
          # Prevent circular reference
          if new_parent.self_and_ancestors.include?(creative)
            return { error: "Cannot move Creative under its own descendant", parent_id: new_parent_id }
          end
        end

        parent_updates[:parent_id] = new_parent_id
      end

      # Apply updates
      success = true

      # Update parent on the creative (for linked creatives, parent is on the link, not origin)
      if parent_updates.present?
        success &&= creative.update(parent_updates)
      end

      # Update content on the base/origin
      if updates.present?
        success &&= base.update(updates)

        # If progress set to 1.0 and has children, complete all descendants
        requested_progress = updates[:progress]
        if success && requested_progress.present? && requested_progress >= 1 && previous_progress.to_f < 1
          if base.children.exists?
            base.self_and_descendants.where(origin_id: nil)
              .update_all(progress: 1.0, updated_at: Time.current)
          end
        end
      end

      if success
        creative.reload
        base.reload
        {
          success: true,
          id: creative.id,
          description: base.description,
          parent_id: creative.parent_id,
          progress: base.progress
        }
      else
        { error: "Failed to update Creative", details: creative.errors.full_messages + base.errors.full_messages }
      end
    end

    private

    def normalize_description(desc)
      return desc if desc.blank?
      # If it already looks like HTML, return as-is
      return desc if desc.strip.start_with?("<")
      # Otherwise wrap in <p> tags
      "<p>#{ERB::Util.html_escape(desc)}</p>"
    end
  end
end
end
