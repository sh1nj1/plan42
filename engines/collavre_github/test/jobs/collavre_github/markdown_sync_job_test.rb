# frozen_string_literal: true

require_relative "../../test_helper"

module CollavreGithub
  class MarkdownSyncJobTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      account = Account.create!(
        user: @user,
        github_uid: "markdown-sync-job",
        login: "sync-job",
        token: "test-token"
      )
      @link = RepositoryLink.create!(
        creative: @creative,
        github_account: account,
        repository_full_name: "owner/repo",
        markdown_sync_enabled: true
      )
    end

    test "records incremental GitHub writes as hidden sync history" do
      creative = @creative
      service = Object.new
      service.define_singleton_method(:call) { creative.update!(description: "GitHub update") }

      MarkdownSync::IncrementalSyncService.stub(:new, ->(**) { service }) do
        MarkdownSyncJob.perform_now(@link.id, {})
      end

      assert_hidden_sync_history
    end

    test "records initial GitHub imports as hidden sync history" do
      creative = @creative
      service = Object.new
      service.define_singleton_method(:call) { creative.update!(description: "Initial GitHub import") }

      MarkdownSync::InitialImportService.stub(:new, ->(**) { service }) do
        InitialMarkdownSyncJob.perform_now(@link.id)
      end

      assert_hidden_sync_history
    end

    test "records initial import directory-first resequencing" do
      parent = Collavre::Creative.create!(description: "Ordered", user: @user)
      file = sourced_creative(parent, "a.md", 0)
      directory = sourced_creative(parent, "z/", 1)
      service = MarkdownSync::InitialImportService.new(repository_link: @link, user: @user)

      Collavre::Creatives::History.track(actor: nil, origin: :sync) do
        service.send(:resequence_directories_first, [ file, directory ])
      end

      assert_equal 0, directory.reload.sequence
      assert_equal 1, file.reload.sequence
      assert_equal [ file.id, directory.id ].sort,
                   Collavre::CreativeChangeSet.sole.creative_changes.pluck(:creative_id).sort
    end

    private

    def assert_hidden_sync_history
      change_set = Collavre::CreativeChangeSet.sole
      assert_equal "sync", change_set.origin
      assert_equal "sync", change_set.actor_kind
      assert_nil change_set.anchor_creative_id
      assert_empty Collavre::CreativeChangeSet.visible_by_default
    end

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
