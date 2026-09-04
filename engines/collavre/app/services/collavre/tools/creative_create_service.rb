module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeCreateService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_create_service"
    tool_description "Create a new Creative (task/content block) in the hierarchical structure. Creatives function like tasks in a tree structure, with automatic progress calculation.\n\nUse this to:\n- Create new tasks under a parent Creative\n- Add sub-items to organize work\n- Build hierarchical project structures\n\nNote: The description field is written as Markdown. A parent with inherited ai_write_policy=review stores a draft in History for approval."

    tool_param :description, description: "The content/title of the Creative, written in Markdown (GitHub-Flavored: headings, bold/italic, lists, links, tables, code blocks, task lists). A single newline is a line break. Plain text is stored as-is. Example: '# Title\\n\\n- item one\\n- item two'.", required: true
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

      Creatives::AiWritePolicy.capture(
        creatives: [ parent, parent&.effective_origin ], anchor: parent
      ) do
        perform_create(
          description: description, parent: parent, progress: progress,
          after_id: after_id, before_id: before_id
        )
      end
    end

    private

    def perform_create(description:, parent:, progress:, after_id:, before_id:)
      # Build the creative. The description is authored as Markdown: store it as
      # the canonical markdown_source and let Describable#convert_markdown_to_html
      # render it to the HTML description (markdown_editor defaults to the
      # advanced "source" surface for tool/MCP writes).
      creative = Creative.new(
        parent: parent,
        progress: progress || 0
      )
      creative.content_type_input = "markdown"
      creative.markdown_source = description

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

      resequence(siblings)
    end

    def resequence(siblings)
      Creatives::History.record_bulk(siblings, operation: "reorder") do
        siblings.each_with_index { |creative, index| creative.update_column(:sequence, index) }
      end
    end
  end
end
end
