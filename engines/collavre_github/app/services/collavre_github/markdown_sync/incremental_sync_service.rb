module CollavreGithub
  module MarkdownSync
    class IncrementalSyncService
      def initialize(repository_link:, push_payload:)
        @link = repository_link
        @payload = push_payload
        @client = CollavreGithub::Client.new(repository_link.github_account)
        @repo = repository_link.repository_full_name
        @user = repository_link.creative.user
      end

      def call
        return unless @link.markdown_sync_enabled?
        return unless target_branch_push?

        root = @link.markdown_root_creative
        return unless root

        commits = @payload["commits"] || []
        return if commits.empty?

        added_paths = []
        modified_paths = []
        removed_paths = []

        commits.each do |commit|
          added_paths.concat(Array(commit["added"]))
          modified_paths.concat(Array(commit["modified"]))
          removed_paths.concat(Array(commit["removed"]))
        end

        # Only care about .md files
        added_paths = added_paths.uniq.select { |p| p.end_with?(".md") }
        modified_paths = modified_paths.uniq.select { |p| p.end_with?(".md") }
        removed_paths = removed_paths.uniq.select { |p| p.end_with?(".md") }

        # Remove from modified if also in added (new file)
        modified_paths -= added_paths

        return if added_paths.empty? && modified_paths.empty? && removed_paths.empty?

        branch = @link.markdown_sync_branch

        # Pre-fetch tree once for SHA lookups (avoid per-file API calls)
        @tree_cache = @client.tree(@repo, branch).each_with_object({}) do |entry, h|
          h[entry.path] = entry.sha
        end

        @synced_creatives = load_synced_creatives
        processor = ContentProcessor.new(
          client: @client, repo: @repo, branch: branch,
          path_to_creative_map: @synced_creatives
        )

        created = []

        removed_paths.each do |path|
          creative = @synced_creatives[path]
          next unless creative
          creative.archive! if creative.respond_to?(:archive!)
          @synced_creatives.delete(path)
        end

        modified_paths.each do |path|
          creative = @synced_creatives[path]
          next unless creative

          content = @client.file_content(@repo, path, ref: branch)
          next if content.blank?

          source = creative.data["source"].merge(
            "markdown" => content,
            "sha" => @tree_cache[path]
          )
          source.delete("rendered_html")
          creative.skip_github_validation = true
          creative.update!(data: creative.data.merge("source" => source))

          processed, blobs = processor.process(content, path)
          update_content_comment(creative, processed, blobs)
        end

        added_paths.each do |path|
          parts = path.split("/")
          parts.pop

          parent = ensure_parent_directories(parts, root)
          content = @client.file_content(@repo, path, ref: branch)
          next if content.blank?

          filename = path.split("/").last
          creative = Collavre::Creative.new(
            description: filename,
            parent: parent,
            user: @user,
            data: {
              "source" => {
                "type" => "github_markdown",
                "repo" => @repo,
                "path" => path,
                "sha" => @tree_cache[path],
                "markdown" => content,
                "repository_link_id" => @link.id
              }
            }
          )
          creative.skip_github_validation = true
          creative.save!
          @synced_creatives[path] = creative

          processed, blobs = processor.process(content, path)
          comment = create_content_comment(creative, processed)
          attach_blobs(comment, blobs) if blobs.any?
          created << creative
        end

        resequence_affected_parents(created)
        @link.update!(last_synced_at: Time.current)
        Collavre::Creative::RealtimeBroadcastable.broadcast_batch_created(created) if created.any?
      end

      private

      def target_branch_push?
        ref = @payload["ref"]
        branch = ref&.sub("refs/heads/", "")
        branch == @link.markdown_sync_branch
      end

      # Load all synced creatives for this repository link, indexed by path
      def load_synced_creatives
        scope = Collavre::Creative.where(archived_at: nil)

        if scope.connection.adapter_name == "PostgreSQL"
          scope = scope.where("(data->'source'->>'repository_link_id')::integer = ?", @link.id)
        else
          scope = scope.where("json_extract(data, '$.source.repository_link_id') = ?", @link.id)
        end

        scope.each_with_object({}) { |c, h| h[c.data.dig("source", "path")] = c }
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

      def update_content_comment(creative, markdown_content, blobs = [])
        topic = creative.content_topic(fallback_user: @user)
        comment = creative.comments.where(topic: topic).order(:created_at).first
        if comment
          comment.images.purge if comment.images.attached?
          comment.update!(content: markdown_content)
          attach_blobs(comment, blobs) if blobs.any?
        else
          comment = create_content_comment(creative, markdown_content)
          attach_blobs(comment, blobs) if blobs.any?
        end
      end

      def attach_blobs(comment, blobs)
        blobs.each { |blob| comment.images.attach(blob) }
      end

      def resequence_affected_parents(new_creatives)
        parent_ids = new_creatives.map(&:parent_id).compact.uniq
        Collavre::Creative.transaction do
          parent_ids.each do |pid|
            siblings = Collavre::Creative.where(parent_id: pid, archived_at: nil)
              .select(:id, :data, :description, :sequence)
            sorted = siblings.sort_by do |c|
              path = c.data&.dig("source", "path") || ""
              is_dir = path.end_with?("/") || path == ""
              [is_dir ? 0 : 1, c.description.to_s.downcase]
            end
            sorted.each_with_index do |c, idx|
              c.update_column(:sequence, idx) if c.sequence != idx
            end
          end
        end
      end

      def ensure_parent_directories(parts, root)
        parent = root
        current_path = ""

        parts.each do |part|
          current_path = current_path.empty? ? part : "#{current_path}/#{part}"
          dir_path = "#{current_path}/"

          existing = @synced_creatives[dir_path]

          if existing
            parent = existing
          else
            dir_creative = Collavre::Creative.new(
              description: part,
              parent: parent,
              user: @user,
              data: {
                "source" => {
                  "type" => "github_markdown",
                  "repo" => @repo,
                  "path" => dir_path,
                  "repository_link_id" => @link.id
                }
              }
            )
            dir_creative.skip_github_validation = true
            dir_creative.save!
            @synced_creatives[dir_path] = dir_creative
            parent = dir_creative
          end
        end

        parent
      end
    end
  end
end
