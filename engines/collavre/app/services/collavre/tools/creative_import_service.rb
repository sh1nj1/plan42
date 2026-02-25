module Collavre
  require "sorbet-runtime"
  require "rails_mcp_engine"

  module Tools
    class CreativeImportService
      extend T::Sig
      extend ToolMeta

      tool_name "creative_import_service"
      tool_description "Import a markdown document as a Creative tree structure. " \
                       "Headings (# through ######) become nested Creatives, preserving the hierarchy. " \
                       "Body text under each heading becomes the Creative's description content.\n\n" \
                       "Example input:\n" \
                       "```\n# Project Plan\n## Phase 1\nSetup infrastructure\n## Phase 2\nBuild features\n### Feature A\nDetails...\n```\n\n" \
                       "This creates:\n" \
                       "- Project Plan\n  - Phase 1 (with body 'Setup infrastructure')\n  - Phase 2 (with body 'Build features')\n    - Feature A (with body 'Details...')\n\n" \
                       "This tool requires approval before execution."

      def self.requires_approval?
        true
      end

      tool_param :markdown, description: "The markdown text to import. Headings define the tree structure.", required: true
      tool_param :parent_id, description: "ID of the parent Creative to import under. The entire markdown tree will be created as children of this Creative.", required: true

      sig { params(markdown: String, parent_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def call(markdown:, parent_id:)
        raise "Current.user is required" unless Current.user

        parent = Creative.find_by(id: parent_id)
        return { error: "Parent Creative not found", id: parent_id } unless parent
        return { error: "No write permission on parent Creative", id: parent_id } unless parent.has_permission?(Current.user, :write)

        nodes = parse_markdown(markdown)
        return { error: "No headings found in markdown" } if nodes.empty?

        created = []
        ApplicationRecord.transaction do
          import_nodes(nodes, parent, created)
        end

        {
          success: true,
          parent_id: parent_id,
          created_count: created.size,
          tree: build_result_tree(created)
        }
      end

      private

      # Parse markdown into a flat list of { level, title, body } nodes
      def parse_markdown(markdown)
        lines = markdown.lines
        nodes = []
        current_node = nil

        lines.each do |line|
          if line =~ /\A(\#{1,6})\s+(.+)/
            # Save previous node
            finalize_node(current_node, nodes) if current_node
            level = $1.length
            title = $2.strip
            current_node = { level: level, title: title, body_lines: [] }
          elsif current_node
            current_node[:body_lines] << line
          end
          # Lines before first heading are ignored
        end

        finalize_node(current_node, nodes) if current_node
        nodes
      end

      def finalize_node(node, nodes)
        body = node[:body_lines].join.strip
        nodes << {
          level: node[:level],
          title: node[:title],
          body: body.presence
        }
      end

      # Import parsed nodes as Creative tree under parent
      def import_nodes(nodes, root_parent, created)
        # Stack tracks [level, creative] pairs for parent resolution
        stack = [ [ 0, root_parent ] ]

        nodes.each_with_index do |node, idx|
          # Pop stack until we find a parent at a lower level
          while stack.size > 1 && stack.last[0] >= node[:level]
            stack.pop
          end

          parent_creative = stack.last[1]
          description = build_description(node[:title], node[:body])

          creative = Creative.new(
            description: description,
            parent: parent_creative,
            user: parent_creative.user,
            progress: 0
          )

          unless creative.save
            raise ActiveRecord::Rollback, "Failed to create Creative at index #{idx}: #{creative.errors.full_messages.join(', ')}"
          end

          created << { id: creative.id, level: node[:level], title: node[:title], parent_id: parent_creative.id }
          stack.push([ node[:level], creative ])
        end
      end

      def build_description(title, body)
        if body.present?
          # Title as heading, body as content
          "<h1>#{ERB::Util.html_escape(title)}</h1>#{markdown_to_html(body)}"
        else
          "<p>#{ERB::Util.html_escape(title)}</p>"
        end
      end

      def markdown_to_html(text)
        # Simple markdown to HTML conversion for body content
        # Convert paragraphs (double newline separated)
        paragraphs = text.split(/\n{2,}/)
        paragraphs.map do |para|
          para = para.strip
          next if para.empty?

          if para.start_with?("- ") || para.start_with?("* ")
            # Unordered list
            items = para.lines.map { |l| l.sub(/\A[-*]\s+/, "").strip }
            "<ul>#{items.map { |i| "<li>#{ERB::Util.html_escape(i)}</li>" }.join}</ul>"
          elsif para =~ /\A\d+\.\s/
            # Ordered list
            items = para.lines.map { |l| l.sub(/\A\d+\.\s+/, "").strip }
            "<ol>#{items.map { |i| "<li>#{ERB::Util.html_escape(i)}</li>" }.join}</ol>"
          else
            "<p>#{ERB::Util.html_escape(para)}</p>"
          end
        end.compact.join
      end

      def build_result_tree(created)
        created.map do |c|
          { id: c[:id], title: c[:title], level: c[:level], parent_id: c[:parent_id] }
        end
      end
    end
  end
end
