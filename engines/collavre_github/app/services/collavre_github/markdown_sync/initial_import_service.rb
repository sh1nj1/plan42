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
        branch = resolve_branch
        tree_entries = @client.tree(@repo, branch)
        md_entries = tree_entries.select { |e| e.type == "blob" && e.path.end_with?(".md") }

        if md_entries.size > MAX_FILES
          Rails.logger.warn("[MarkdownSync] #{@repo}: #{md_entries.size} .md files found, limiting to #{MAX_FILES}")
          md_entries = md_entries.first(MAX_FILES)
        end

        parent_creative = @link.creative
        root_creative = create_root_creative(parent_creative)
        @link.update!(markdown_root_creative_id: root_creative.id, last_synced_at: Time.current)

        dir_map = { "" => root_creative }
        created = [ root_creative ]
        file_creatives = []

        if md_entries.empty?
          Collavre::Creative::RealtimeBroadcastable.broadcast_batch_created(created) if created.size > 1
          return created
        end

        md_entries.sort_by(&:path).each do |entry|
          parts = entry.path.split("/")
          filename = parts.pop

          parent = ensure_directories(parts, dir_map, root_creative, created)

          content = @client.file_content(@repo, entry.path, ref: branch)
          next if content.blank?

          creative = Collavre::Creative.new(
            description: filename,
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
          creative.skip_github_validation = true
          creative.save!
          file_creatives << creative
          created << creative
        end

        # Second pass: resolve relative links and images now that all creatives exist
        path_map = build_path_map(created)
        processor = ContentProcessor.new(client: @client, repo: @repo, branch: branch, path_to_creative_map: path_map)

        file_creatives.each do |creative|
          raw_md = creative.data.dig("source", "markdown")
          next if raw_md.blank?

          processed, blobs = processor.process(raw_md, creative.data.dig("source", "path"))
          comment = create_content_comment(creative, processed)
          attach_blobs(comment, blobs) if blobs.any?
        end

        resequence_directories_first(created)
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
        creative = Collavre::Creative.new(
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
        creative.skip_github_validation = true
        creative.save!
        creative
      end

      def build_path_map(creatives)
        creatives.each_with_object({}) do |c, map|
          path = c.data&.dig("source", "path")
          map[path] = c if path.present?
        end
      end

      def create_content_comment(creative, markdown_content)
        topic = creative.content_topic(fallback_user: @user)
        creative.comments.create!(
          content: markdown_content,
          topic: topic,
          user: @user,
          skip_dispatch: true
        )
      end

      def attach_blobs(comment, blobs)
        blobs.each { |blob| comment.images.attach(blob) }
      end

      def resequence_directories_first(creatives)
        Collavre::Creative.transaction do
          creatives.group_by(&:parent_id).each do |_parent_id, siblings|
            sorted = siblings.sort_by do |c|
              path = c.data&.dig("source", "path") || ""
              is_dir = path.end_with?("/") || path == ""
              [ is_dir ? 0 : 1, c.description.to_s.downcase ]
            end
            sorted.each_with_index do |c, idx|
              c.update_column(:sequence, idx)
            end
          end
        end
      end

      def ensure_directories(parts, dir_map, root, created)
        current_path = ""
        parent = root

        parts.each do |part|
          current_path = current_path.empty? ? part : "#{current_path}/#{part}"
          unless dir_map[current_path]
            dir_creative = Collavre::Creative.new(
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
            dir_creative.skip_github_validation = true
            dir_creative.save!
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
