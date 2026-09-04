require_relative "../../../test_helper"

module CollavreGithub
  module MarkdownSync
    class IncrementalSyncServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "999901",
          login: "sync-test-user",
          name: "Sync Test",
          token: "test-token"
        )
        @creative = creatives(:tshirt)
        @link = CollavreGithub::RepositoryLink.create!(
          creative: @creative,
          github_account: @account,
          repository_full_name: "owner/repo"
        )
        @other_link = CollavreGithub::RepositoryLink.create!(
          creative: @creative,
          github_account: @account,
          repository_full_name: "owner/other-repo"
        )

        @matching = Collavre::Creative.create!(
          description: "matching.md",
          parent: @creative,
          user: @user,
          data: {
            "source" => {
              "type" => "github_markdown",
              "path" => "docs/matching.md",
              "repository_link_id" => @link.id
            }
          }
        )

        @non_matching_link = Collavre::Creative.create!(
          description: "other-link.md",
          parent: @creative,
          user: @user,
          data: {
            "source" => {
              "type" => "github_markdown",
              "path" => "docs/other-link.md",
              "repository_link_id" => @other_link.id
            }
          }
        )

        @archived_match = Collavre::Creative.create!(
          description: "archived.md",
          parent: @creative,
          user: @user,
          archived_at: Time.current,
          data: {
            "source" => {
              "type" => "github_markdown",
              "path" => "docs/archived.md",
              "repository_link_id" => @link.id
            }
          }
        )

        @no_source = Collavre::Creative.create!(
          description: "unrelated",
          parent: @creative,
          user: @user
        )

        @service = IncrementalSyncService.new(repository_link: @link, push_payload: {})
      end

      test "load_synced_creatives scopes to creatives whose JSON-embedded repository_link_id matches, keyed by path" do
        synced = @service.send(:load_synced_creatives)

        assert_equal({ "docs/matching.md" => @matching }, synced)
      end

      test "load_synced_creatives excludes creatives linked to a different repository_link_id" do
        synced = @service.send(:load_synced_creatives)

        assert_not_includes synced.values, @non_matching_link
      end

      test "load_synced_creatives excludes archived creatives even when repository_link_id matches" do
        synced = @service.send(:load_synced_creatives)

        assert_not_includes synced.values, @archived_match
      end

      test "load_synced_creatives excludes creatives with no source/repository_link_id at all" do
        synced = @service.send(:load_synced_creatives)

        assert_not_includes synced.values, @no_source
      end

      test "resequence_affected_parents records every changed sibling" do
        parent = Collavre::Creative.create!(description: "Ordered", user: @user)
        file = sourced_creative(parent, "a.md", 0)
        directory = sourced_creative(parent, "z/", 1)

        Collavre::Creatives::History.track(actor: nil, origin: :sync) do
          @service.send(:resequence_affected_parents, [ file, directory ])
        end

        assert_equal 0, directory.reload.sequence
        assert_equal 1, file.reload.sequence
        assert_equal [ file.id, directory.id ].sort,
                     Collavre::CreativeChangeSet.sole.creative_changes.pluck(:creative_id).sort
      end

      private

      def sourced_creative(parent, path, sequence)
        Collavre::Creative.create!(
          description: path,
          parent: parent,
          user: @user,
          sequence: sequence,
          data: { "source" => { "path" => path } }
        )
      end
    end
  end
end
