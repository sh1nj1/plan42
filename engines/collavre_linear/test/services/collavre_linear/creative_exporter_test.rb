# frozen_string_literal: true

require "test_helper"
require "digest"

module CollavreLinear
  class CreativeExporterTest < ActiveSupport::TestCase
    # ---------------------------------------------------------------------------
    # Plain stub — no network; conforms to Client's public interface.
    # ---------------------------------------------------------------------------
    class FakeClient
      attr_reader :create_calls, :update_calls

      def initialize(create_response: { id: "iss-new", identifier: "ENG-1" },
                     update_response: { id: "iss-new", identifier: "ENG-1" })
        @create_response = create_response
        @update_response = update_response
        @create_calls    = []
        @update_calls    = []
      end

      def create_issue(**kwargs)
        @create_calls << kwargs
        @create_response
      end

      def update_issue(id, **kwargs)
        @update_calls << kwargs.merge(_id: id)
        @update_response
      end
    end

    # ---------------------------------------------------------------------------
    # Shared setup helpers
    # ---------------------------------------------------------------------------

    def setup
      @user = Collavre.user_class.create!(
        email: "exporter-test-#{SecureRandom.hex(4)}@example.com",
        name: "Exporter Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-exp-#{SecureRandom.hex(4)}",
        access_token: "tok-exp"
      )

      # Root creative is the one that holds the ProjectLink.
      @root_creative = Collavre::Creative.create!(
        description: "<p>Root</p>",
        user: @user
      )

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @root_creative,
        account:  @account,
        linear_project_id: "proj-exp",
        team_id:           "team-exp"
      )

      # Child creative is the one we actually export. Suppress the auto-sync
      # observer during construction: these tests drive the exporter directly
      # and don't want the inline OutboundSyncJob firing (and hitting the
      # network) at commit time.
      @child_creative = Collavre::Creative.new(
        description: "<p>Child</p>",
        user: @user,
        parent: @root_creative
      )
      @child_creative.skip_linear_sync = true
      @child_creative.save!

      @fake_client = FakeClient.new
    end

    # ---------------------------------------------------------------------------
    # Step 1 — CREATE path
    # ---------------------------------------------------------------------------

    test "sync! calls create_issue with mapped attrs and parent's linear_issue_id" do
      # Give the root creative its own IssueLink so the parent_id resolves.
      root_issue_link = CollavreLinear::IssueLink.create!(
        creative:        @root_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-parent-root",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 1, @fake_client.create_calls.size, "create_issue should be called once"

      call = @fake_client.create_calls.first
      assert_equal "team-exp",   call[:team_id]
      assert_equal "proj-exp",   call[:project_id]
      assert_equal "iss-parent-root", call[:parent_id],
        "parent_id should be the root IssueLink's linear_issue_id"
      assert_equal @child_creative.description, call[:description]
    end

    test "sync! persists an IssueLink with content_hash after create" do
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_not_nil link,        "IssueLink must be created"
      assert_not_nil link.content_hash, "content_hash must be persisted"
      assert_equal "iss-new",    link.linear_issue_id
      assert_equal :synced,      link.sync_state.to_sym
      assert_equal 1,            link.local_version
    end

    test "sync! resolves project_link from ancestor when creative has no direct link" do
      # @child_creative has no ProjectLink; only @root_creative does.
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      # Should have created an IssueLink under the ancestor's project.
      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_not_nil link
      assert_equal @project_link, link.project_link
    end

    test "sync! is a no-op when no ProjectLink exists on self or ancestors" do
      orphan = Collavre::Creative.create!(description: "<p>Orphan</p>", user: @user)

      CollavreLinear::Client.stub(:new, @fake_client) do
        result = CollavreLinear::CreativeExporter.new(orphan).sync!
        assert_nil result
      end

      assert_equal 0, @fake_client.create_calls.size
      assert_equal 0, @fake_client.update_calls.size
    end

    # ---------------------------------------------------------------------------
    # Step 2a — UPDATE path (changed content)
    # ---------------------------------------------------------------------------

    test "sync! calls update_issue when IssueLink exists and content has changed" do
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-existing",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      before = Time.current

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 1, @fake_client.update_calls.size, "update_issue should be called once"
      assert_equal "iss-existing", @fake_client.update_calls.first[:_id]

      existing_link.reload
      assert_not_equal "old-hash-that-will-not-match", existing_link.content_hash
      assert_equal 1, existing_link.local_version

      # EchoGuard must stamp last_outbound_at on the update path, same as create.
      assert_not_nil existing_link.last_outbound_at,
        "EchoGuard must stamp last_outbound_at after update"
      assert existing_link.last_outbound_at >= before,
        "last_outbound_at must be at or after the sync! call"
    end

    # ---------------------------------------------------------------------------
    # Step 2b — dirty-tracking (unchanged content → NO API call)
    # ---------------------------------------------------------------------------

    test "sync! skips the API call when content_hash is unchanged" do
      # Compute the hash through the canonical exporter path (parent-aware).
      hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative)

      CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-no-change",
        content_hash:    hash,
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 0, @fake_client.update_calls.size,
        "update_issue must NOT be called when content_hash is unchanged"
      assert_equal 0, @fake_client.create_calls.size
    end

    # ---------------------------------------------------------------------------
    # Step 2c — dirty link with unchanged content → reset to :synced (Fix 1)
    # ---------------------------------------------------------------------------

    test "sync! resets :dirty link to :synced without an API call when content is unchanged" do
      # Compute the current content hash via the canonical exporter path.
      hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative)

      # Simulate what the observer does on a metadata-only save: mark dirty
      # without changing any mapped field.
      dirty_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-dirty-noop",
        content_hash:    hash,
        sync_state:      :dirty
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      # No API call must be made — content is identical.
      assert_equal 0, @fake_client.update_calls.size,
        "update_issue must NOT be called when content_hash is unchanged"
      assert_equal 0, @fake_client.create_calls.size

      # The link must no longer be :dirty so inbound updates don't trip conflict?.
      dirty_link.reload
      assert_equal "synced", dirty_link.sync_state,
        "sync_state must be reset to :synced after a no-op export"
    end

    test "dirty link reset prevents false conflict on subsequent inbound update" do
      hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative)

      dirty_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-dirty-noop2",
        content_hash:    hash,
        sync_state:      :dirty
      )

      # Run the exporter — should reset :dirty → :synced.
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      dirty_link.reload
      assert_equal "synced", dirty_link.sync_state

      # After reset, conflict? must return false (InboundApplier keyed condition).
      assert_not dirty_link.dirty?,
        "dirty? must be false after the no-op export resets sync_state"
    end

    # ---------------------------------------------------------------------------
    # Step 2d — reparent pushes parentId on update (hierarchy divergence fix)
    # ---------------------------------------------------------------------------

    test "sync! pushes parentId to Linear when a linked creative is reparented under a different linked parent" do
      # Root already holds a linked issue (the ORIGINAL parent of @child_creative).
      CollavreLinear::IssueLink.create!(
        creative:        @root_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-old-parent",
        sync_state:      :synced
      )

      # A SECOND linked creative to move the child under.
      new_parent = Collavre::Creative.new(
        description: "<p>New parent</p>", user: @user, parent: @root_creative
      )
      new_parent.skip_linear_sync = true
      new_parent.save!
      CollavreLinear::IssueLink.create!(
        creative:        new_parent,
        project_link:    @project_link,
        linear_issue_id: "iss-new-parent",
        sync_state:      :synced
      )

      # The child already has an IssueLink whose content_hash reflects its state
      # under the OLD parent (iss-old-parent).
      old_hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative)
      child_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-child",
        content_hash:    old_hash,
        sync_state:      :synced
      )

      # Reparent the child under the new linked parent (content unchanged).
      @child_creative.skip_linear_sync = true
      @child_creative.update!(parent: new_parent)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 1, @fake_client.update_calls.size,
        "reparent must trigger update_issue even though content fields are unchanged"
      call = @fake_client.update_calls.first
      assert_equal "iss-child", call[:_id]
      assert_equal "iss-new-parent", call[:parent_id],
        "update_issue must carry the NEW parent's linear_issue_id as parent_id"

      child_link.reload
      assert_not_equal old_hash, child_link.content_hash,
        "content_hash must advance to reflect the new parent"
    end

    test "sync! does not add a spurious parentId change on a same-parent content edit" do
      # Root holds a linked issue = the child's parent.
      CollavreLinear::IssueLink.create!(
        creative:        @root_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-parent-stable",
        sync_state:      :synced
      )

      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-content-edit",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      # Content changed → update runs. Because the parent is UNCHANGED (still the
      # linked root), parentId is still sent (idempotent — same value), but the
      # point is we don't fabricate a bogus/nil parentId that would error.
      assert_equal 1, @fake_client.update_calls.size
      call = @fake_client.update_calls.first
      assert_equal "iss-parent-stable", call[:parent_id],
        "the stable linked parent's id should be sent, not nil"
      existing_link.reload
      assert_not_equal "old-hash-that-will-not-match", existing_link.content_hash
    end

    test "sync! omits parentId on update when the creative has no linked parent" do
      # @child_creative's parent (@root_creative) has NO IssueLink → parent is
      # not a linked Linear issue, so no parentId must be sent (would error).
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-no-linked-parent",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 1, @fake_client.update_calls.size
      call = @fake_client.update_calls.first
      assert_not call.key?(:parent_id),
        "no parent_id must be sent when the parent is not a linked Linear issue"
      existing_link.reload
      assert_not_equal "old-hash-that-will-not-match", existing_link.content_hash
    end

    # ---------------------------------------------------------------------------
    # Client::Error re-raise
    # ---------------------------------------------------------------------------

    test "sync! re-raises Client::Error so the job can retry" do
      error_client = Class.new do
        def create_issue(**); raise CollavreLinear::Client::Error, "boom"; end
        def update_issue(*, **); raise CollavreLinear::Client::Error, "boom"; end
      end.new

      CollavreLinear::Client.stub(:new, error_client) do
        assert_raises(CollavreLinear::Client::Error) do
          CollavreLinear::CreativeExporter.new(@child_creative).sync!
        end
      end
    end

    # ---------------------------------------------------------------------------
    # EchoGuard stamp
    # ---------------------------------------------------------------------------

    test "sync! stamps last_outbound_at via EchoGuard after create" do
      before = Time.current
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_not_nil link.last_outbound_at
      assert link.last_outbound_at >= before
    end
  end
end
