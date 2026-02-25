module Collavre
  require "sorbet-runtime"
  require "rails_mcp_engine"

  module Tools
    class CreativeImportService
      extend T::Sig
      extend ToolMeta

      tool_name "creative_import_service"
      tool_description "Import a markdown document as a Creative tree structure using the built-in MarkdownImporter. " \
                       "Headings (# through ######) become nested Creatives, preserving the hierarchy. " \
                       "Bullet lists (-, *, +) become nested children with indent-based depth. " \
                       "Tables, fenced code blocks, and inline images are also supported.\n\n" \
                       "Example input:\n" \
                       "```\n# Project Plan\n## Phase 1\n- Setup infrastructure\n- Configure CI\n## Phase 2\n- Build features\n```\n\n" \
                       "This creates a tree under the specified parent Creative.\n\n" \
                       "This tool requires approval before execution."

      def self.requires_approval?
        true
      end

      tool_param :markdown, description: "The markdown text to import. Headings and bullet lists define the tree structure.", required: true
      tool_param :parent_id, description: "ID of the parent Creative to import under. The entire markdown tree will be created as children of this Creative.", required: true

      sig { params(markdown: String, parent_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def call(markdown:, parent_id:)
        raise "Current.user is required" unless Current.user

        parent = Creative.find_by(id: parent_id)
        return { error: "Parent Creative not found", id: parent_id } unless parent
        return { error: "No write permission on parent Creative", id: parent_id } unless parent.has_permission?(Current.user, :write)

        created = MarkdownImporter.import(markdown, parent: parent, user: Current.user)

        {
          success: true,
          parent_id: parent_id,
          created_count: created.size,
          tree: created.map { |c| { id: c.id, description: c.description.to_s.truncate(100), parent_id: c.parent_id } }
        }
      end
    end
  end
end
