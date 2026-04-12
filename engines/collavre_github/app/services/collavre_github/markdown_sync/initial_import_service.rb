module CollavreGithub
  module MarkdownSync
    class InitialImportService
      MAX_FILES = 200

      def initialize(repository_link:, user:)
        @link = repository_link
        @user = user
        @client = CollavreGithub::Client.new(repository_link.github_account)
        @repo = repository_link.repository_full_name
      end

      def call
        Collavre::Current.markdown_sync = true
        branch = resolve_branch
        tree_entries = @client.tree(@repo, branch)
        md_entries = tree_entries.select { |e| e.type == "blob" && e.path.end_with?(".md") }

        if md_entries.size > MAX_FILES
          Rails.logger.warn("[MarkdownSync] #{@repo}: #{md_entries.size} .md files found, limiting to #{MAX_FILES}")
          md_entries = md_entries.first(MAX_FILES)
        end

        return if md_entries.empty?

        parent_creative = @link.creative
        root_creative = create_root_creative(parent_creative)
        @link.update!(markdown_root_creative_id: root_creative.id, last_synced_at: Time.current)

        # Build directory structure and file creatives
        dir_map = { "" => root_creative }
        created = [ root_creative ]

        # Sort entries by path to ensure parent dirs come first
        md_entries.sort_by(&:path).each do |entry|
          parts = entry.path.split("/")
          filename = parts.pop
          dir_path = parts.join("/")

          # Ensure all parent directories exist
          parent = ensure_directories(parts, dir_map, root_creative, created)

          # Fetch file content and create creative
          content = @client.file_content(@repo, entry.path, ref: branch)
          next if content.blank?

          rendered_html = Collavre::MarkdownConverter.markdown_to_html(content)
          creative = Collavre::Creative.create!(
            description: rendered_html,
            parent: parent,
            user: @user,
            data: {
              "source" => {
                "type" => "github_markdown",
                "repo" => @repo,
                "path" => entry.path,
                "sha" => entry.sha,
                "markdown" => content,
                "repository_link_id" => @link.id
              }
            }
          )
          created << creative
        end

        Collavre::Creative::RealtimeBroadcastable.broadcast_batch_created(created) if created.size > 1
        created
      end

      private

      def resolve_branch
        if @link.sync_branch.present?
          @link.sync_branch
        else
          branch = @client.default_branch(@repo)
          @link.update_column(:sync_branch, branch)
          branch
        end
      end

      def create_root_creative(parent)
        repo_name = @repo.split("/").last
        Collavre::Creative.create!(
          description: repo_name,
          parent: parent,
          user: @user,
          data: {
            "source" => {
              "type" => "github_markdown",
              "repo" => @repo,
              "path" => "",
              "repository_link_id" => @link.id
            }
          }
        )
      end

      def ensure_directories(parts, dir_map, root, created)
        current_path = ""
        parent = root

        parts.each do |part|
          current_path = current_path.empty? ? part : "#{current_path}/#{part}"
          unless dir_map[current_path]
            dir_creative = Collavre::Creative.create!(
              description: part,
              parent: parent,
              user: @user,
              data: {
                "source" => {
                  "type" => "github_markdown",
                  "repo" => @repo,
                  "path" => "#{current_path}/",
                  "repository_link_id" => @link.id
                }
              }
            )
            dir_map[current_path] = dir_creative
            created << dir_creative
          end
          parent = dir_map[current_path]
        end

        parent
      end
    end
  end
end
