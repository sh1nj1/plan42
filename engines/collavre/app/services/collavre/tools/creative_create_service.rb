module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeCreateService
    extend T::Sig
    extend ToolMeta
    include DescriptionNormalizable

    tool_name "creative_create_service"
    tool_description "Create a new Creative (task/content block) in the hierarchical structure. Creatives function like tasks in a tree structure, with automatic progress calculation.\n\nUse this to:\n- Create new tasks under a parent Creative\n- Add sub-items to organize work\n- Build hierarchical project structures\n\nNote: The description field accepts HTML format for rich text content."

    tool_param :description, description: "The content/title of the Creative. Accepts HTML format (e.g., '<p>Task title</p>'). Plain text will be wrapped in <p> tags automatically.", required: true
    tool_param :parent_id, description: "ID of the parent Creative. Required to create under a specific parent. If omitted, creates a root Creative.", required: false
    tool_param :progress, description: "Initial progress value (0.0 to 1.0). Default is 0.", required: false
    tool_param :after_id, description: "ID of a sibling Creative to insert after. Used for ordering.", required: false
    tool_param :before_id, description: "ID of a sibling Creative to insert before. Used for ordering.", required: false

    sig { params(description: String, parent_id: T.nilable(Integer), progress: T.nilable(Numeric), after_id: T.nilable(Integer), before_id: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
    def call(description:, parent_id: nil, progress: nil, after_id: nil, before_id: nil)
      raise "Current.user is required" unless Current.user

      # Validate parent permission if specified
      parent = nil
      if parent_id.present?
        parent = Creative.find_by(id: parent_id)
        unless parent
          return { error: "Parent Creative not found", id: parent_id }
        end
        unless parent.has_permission?(Current.user, :write)
          return { error: "No write permission on parent Creative", id: parent_id }
        end
      end

      # Normalize description - wrap plain text in <p> tags if needed
      normalized_description = normalize_description(description)

      # Build the creative
      creative = Creative.new(
        description: normalized_description,
        parent: parent,
        progress: progress || 0
      )

      # Set user based on parent or current user
      creative.user = parent ? parent.user : Current.user

      unless creative.save
        return { error: "Failed to create Creative", details: creative.errors.full_messages }
      end

      # Handle ordering
      handle_ordering(creative, before_id: before_id, after_id: after_id)

      # Broadcast after ordering so sequence and previous_sibling are correct
      creative.reload
      creative.broadcast_creative_created(after_id: after_id)

      {
        success: true,
        id: creative.id,
        description: creative.description,
        parent_id: creative.parent_id,
        progress: creative.progress
      }
    end

    private

    def handle_ordering(creative, before_id:, after_id:)
      return unless before_id.present? || after_id.present?

      siblings = creative.parent ? creative.parent.children.order(:sequence).to_a : Creative.roots.order(:sequence).to_a
      siblings.reject! { |s| s.id == creative.id }

      if before_id.present?
        before_creative = Creative.find_by(id: before_id)
        if before_creative && before_creative.parent_id == creative.parent_id
          index = siblings.index { |s| s.id == before_creative.id } || 0
          siblings.insert(index, creative)
        end
      elsif after_id.present?
        after_creative = Creative.find_by(id: after_id)
        if after_creative && after_creative.parent_id == creative.parent_id
          index = siblings.index { |s| s.id == after_creative.id } || -1
          siblings.insert(index + 1, creative)
        end
      end

      siblings.each_with_index { |c, idx| c.update_column(:sequence, idx) }
    end
  end
end
end
