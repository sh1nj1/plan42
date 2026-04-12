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
        Collavre::Current.markdown_sync = true
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

        # Pre-load all synced creatives for this link to avoid N+1 queries
        @synced_creatives = load_synced_creatives

        created = []

        # Handle removed files
        removed_paths.each do |path|
          creative = @synced_creatives[path]
          next unless creative
          creative.archive! if creative.respond_to?(:archive!)
          @synced_creatives.delete(path)
        end

        # Handle modified files
        modified_paths.each do |path|
          creative = @synced_creatives[path]
          next unless creative

          content = @client.file_content(@repo, path, ref: branch)
          next if content.blank?

          rendered_html = Collavre::MarkdownConverter.markdown_to_html(content)
          source = creative.data["source"].merge(
            "markdown" => content,
            "sha" => @tree_cache[path]
          )
          creative.update!(description: rendered_html, data: creative.data.merge("source" => source))
        end

        # Handle added files
        added_paths.each do |path|
          parts = path.split("/")
          parts.pop # remove filename

          parent = ensure_parent_directories(parts, root)
          content = @client.file_content(@repo, path, ref: branch)
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
                "path" => path,
                "sha" => @tree_cache[path],
                "markdown" => content,
                "repository_link_id" => @link.id
              }
            }
          )
          @synced_creatives[path] = creative
          created << creative
        end

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
            dir_creative = Collavre::Creative.create!(
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
            @synced_creatives[dir_path] = dir_creative
            parent = dir_creative
          end
        end

        parent
      end
    end
  end
end
