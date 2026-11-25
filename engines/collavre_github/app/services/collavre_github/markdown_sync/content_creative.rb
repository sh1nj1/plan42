module CollavreGithub
  module MarkdownSync
    # A synced markdown file is two creatives: the file creative (filename,
    # path anchor) and a single child content creative holding the file body
    # as markdown_source. Both are github_markdown sources, so the body stays
    # read-only until reverse sync lands.
    module ContentCreative
      ROLE = "content".freeze

      module_function

      def content?(creative)
        creative.data.is_a?(Hash) && creative.data.dig("source", "role") == ROLE
      end

      def find(file_creative)
        file_creative.children.where(archived_at: nil).detect { |child| content?(child) }
      end

      # Creates or updates the content creative under file_creative.
      # Returns the creative when it was newly created, nil otherwise.
      def upsert!(file_creative, markdown, user:)
        existing = find(file_creative)
        if existing
          update!(existing, markdown)
          return nil
        end

        creative = Collavre::Creative.new(
          parent: file_creative,
          user: user,
          data: { "source" => source_for(file_creative) }
        )
        assign_markdown(creative, markdown)
        creative.save!
        creative
      end

      def update!(creative, markdown)
        assign_markdown(creative, markdown)
        creative.skip_read_only_source_validation = true
        creative.save!
      end

      def source_for(file_creative)
        file_creative.data["source"].slice("type", "repo", "path", "repository_link_id").merge("role" => ROLE)
      end

      def assign_markdown(creative, markdown)
        creative.content_type_input = "markdown"
        creative.markdown_editor = "source"
        creative.markdown_source = markdown
      end
    end
  end
end
