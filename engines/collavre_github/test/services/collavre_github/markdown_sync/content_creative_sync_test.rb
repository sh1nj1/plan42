require_relative "../../../test_helper"

module CollavreGithub
  module MarkdownSync
    class ContentCreativeSyncTest < ActiveSupport::TestCase
      TreeEntry = Struct.new(:path, :sha, :type)

      class FakeClient
        attr_accessor :files

        def initialize(files)
          @files = files
        end

        def tree(_repo, _branch)
          @files.keys.map { |path| TreeEntry.new(path, "sha-#{@files[path].hash}", "blob") }
        end

        def file_content(_repo, path, ref: nil)
          @files[path]
        end

        def default_branch(_repo)
          "main"
        end
      end

      setup do
        @user = users(:one)
        account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "content-creative-sync",
          login: "content-sync",
          token: "test-token"
        )
        @link = CollavreGithub::RepositoryLink.create!(
          creative: creatives(:tshirt),
          github_account: account,
          repository_full_name: "owner/repo",
          markdown_sync_enabled: true,
          sync_branch: "main"
        )
        @client = FakeClient.new(
          "README.md" => "# Readme\n\nSee [guide](docs/guide.md).\n",
          "docs/guide.md" => "# Guide\n\n- step one\n"
        )
      end

      test "initial import stores each file body in a markdown content creative under the file creative" do
        import!

        readme = file_creative("README.md")
        content = ContentCreative.find(readme)

        assert content
        assert_equal "markdown", content.data["content_type"]
        assert_equal "source", content.data["editor"]
        guide = file_creative("docs/guide.md")
        assert_equal "# Readme\n\nSee [guide](/creatives/#{guide.id}).\n", content.data["markdown_source"]
        assert_includes content.description, "<h1>Readme</h1>"
        assert_equal(
          { "type" => "github_markdown", "repo" => "owner/repo", "path" => "README.md",
            "repository_link_id" => @link.id, "role" => "content" },
          content.data["source"]
        )
        assert content.read_only_source?
        assert_empty readme.comments
        assert_nil readme.topics.find_by(name: Collavre::Creative::CONTENT_TOPIC_NAME)
      end

      test "incremental sync updates the existing content creative and keeps paths mapped to file creatives" do
        import!
        guide = file_creative("docs/guide.md")
        content = ContentCreative.find(guide)

        @client.files["docs/guide.md"] = "# Guide\n\n- step two\n"
        push!(modified: [ "docs/guide.md" ])

        assert_equal "# Guide\n\n- step two\n", content.reload.data["markdown_source"]
        assert_includes content.description, "step two"
        assert_equal "# Guide\n\n- step two\n", guide.reload.data.dig("source", "markdown")
        assert_equal 1, guide.children.where(archived_at: nil).count

        synced = IncrementalSyncService.new(repository_link: @link, push_payload: {}).send(:load_synced_creatives)
        assert_equal guide, synced["docs/guide.md"]
      end

      test "incremental sync creates file and content creatives for added files" do
        import!
        @client.files["docs/new.md"] = "New body"

        push!(added: [ "docs/new.md" ])

        added = file_creative("docs/new.md")
        assert_equal "New body", ContentCreative.find(added).data["markdown_source"]
      end

      test "incremental sync creates a content creative for legacy files that lack one" do
        import!
        guide = file_creative("docs/guide.md")
        ContentCreative.find(guide).destroy!

        @client.files["docs/guide.md"] = "Migrated body"
        push!(modified: [ "docs/guide.md" ])

        assert_equal "Migrated body", ContentCreative.find(guide.reload).data["markdown_source"]
      end

      test "removing a file archives its content creative with it" do
        import!
        guide = file_creative("docs/guide.md")
        content = ContentCreative.find(guide)

        push!(removed: [ "docs/guide.md" ])

        assert content.reload.archived_at.present?
      end

      test "content? ignores creatives without a hash data payload" do
        assert_not ContentCreative.content?(Collavre::Creative.new(description: "plain"))
      end

      private

      def import!
        CollavreGithub::Client.stub(:new, @client) do
          InitialImportService.new(repository_link: @link, user: @user).call
        end
        @link.reload
      end

      def push!(added: [], modified: [], removed: [])
        payload = {
          "ref" => "refs/heads/main",
          "commits" => [ { "added" => added, "modified" => modified, "removed" => removed } ]
        }
        CollavreGithub::Client.stub(:new, @client) do
          IncrementalSyncService.new(repository_link: @link, push_payload: payload).call
        end
      end

      def file_creative(path)
        Collavre::Creative.where(archived_at: nil).detect do |creative|
          creative.data.is_a?(Hash) &&
            creative.data.dig("source", "path") == path &&
            creative.data.dig("source", "repository_link_id") == @link.id &&
            !ContentCreative.content?(creative)
        end
      end
    end
  end
end
