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

    # Give the root creative its Linear issue so exporting @child_creative on
    # the create path does not defer on the parent-ordering guard. Returns the
    # created root IssueLink.
    def link_root_issue!(linear_issue_id = "iss-root-parent")
      CollavreLinear::IssueLink.create!(
        creative:        @root_creative,
        project_link:    @project_link,
        linear_issue_id: linear_issue_id,
        sync_state:      :synced
      )
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
      link_root_issue!
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

    # Regression: the sync baseline (remote_updated_at) must be stamped from
    # LINEAR's returned updatedAt, not the app clock. The inbound applier compares
    # this baseline against a webhook's Linear-clock updatedAt to decide
    # conflict-vs-stale; an app-clock baseline (Time.current) can exceed a genuine
    # remote edit's Linear updatedAt (clock skew + round-trip latency) and drop it
    # as a "stale echo" — a silent lost update. Use a fixed, unmistakably-non-now
    # timestamp so a Time.current regression fails loudly.
    test "sync! baselines remote_updated_at on Linear's updatedAt after create" do
      link_root_issue!
      linear_ts = "2020-01-02T03:04:05Z"
      fake = FakeClient.new(
        create_response: { id: "iss-new", identifier: "ENG-1", updatedAt: linear_ts }
      )

      CollavreLinear::Client.stub(:new, fake) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_equal Time.zone.parse(linear_ts), link.remote_updated_at,
        "baseline must be Linear's updatedAt (Linear clock), not Time.current"
    end

    test "sync! baselines remote_updated_at on Linear's updatedAt after update" do
      link_root_issue!
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-existing",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )
      linear_ts = "2020-06-07T08:09:10Z"
      fake = FakeClient.new(
        update_response: { id: "iss-existing", identifier: "ENG-2", updatedAt: linear_ts }
      )

      CollavreLinear::Client.stub(:new, fake) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      existing_link.reload
      assert_equal Time.zone.parse(linear_ts), existing_link.remote_updated_at,
        "update must re-baseline on Linear's updatedAt (Linear clock), not Time.current"
    end

    test "sync! resolves project_link from ancestor when creative has no direct link" do
      # @child_creative has no ProjectLink; only @root_creative does.
      # Give the root its Linear issue first so the child does not defer on the
      # parent-ordering guard — this test is about project_link resolution.
      link_root_issue!("iss-parent-ancestor")

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      # Should have created an IssueLink under the ancestor's project.
      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_not_nil link
      assert_equal @project_link, link.project_link
    end

    test "sync! reconciles a self-echo race: adopts the inbound link and removes the duplicate" do
      link_root_issue!

      # Simulate the inbound webhook echo of our own issueCreate racing ahead of
      # our IssueLink insert: a duplicate Creative under the project root already
      # holds the IssueLink for the id create_issue will return ("iss-new").
      duplicate = Collavre::Creative.new(
        description: "<p>echo dup</p>",
        user: @user,
        parent: @root_creative
      )
      duplicate.skip_linear_sync = true
      duplicate.save!
      CollavreLinear::IssueLink.create!(
        creative:        duplicate,
        project_link:    @project_link,
        linear_issue_id: "iss-new",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      # Exactly one IssueLink for the id, now pointing at our original creative.
      links = CollavreLinear::IssueLink.where(linear_issue_id: "iss-new")
      assert_equal 1, links.size, "the duplicate IssueLink must be reconciled to one"
      assert_equal @child_creative.id, links.first.creative_id,
        "the surviving link must point at our original creative, not the echo duplicate"
      # The inbound duplicate creative is removed (and its removal must NOT archive
      # the Linear issue we just created — the link was moved off it first).
      assert_nil Collavre::Creative.find_by(id: duplicate.id),
        "the echo duplicate creative must be removed"
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
      link_root_issue! # consistent topology: parent exported before child
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

    test "sync! does NOT push to Linear when the link is in :conflict state" do
      link_root_issue! # consistent topology: parent exported before child
      # A newer inbound webhook flipped the link to :conflict. Even though content
      # differs (stale hash) and a job was queued, auto-sync must HALT until an
      # explicit resync — otherwise we overwrite the remote change we chose to keep.
      conflicted = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-conflict",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :conflict
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 0, @fake_client.update_calls.size,
        "update_issue must NOT be called while the link is in :conflict"
      conflicted.reload
      assert_equal :conflict, conflicted.sync_state.to_sym,
        "conflict state must persist until an explicit resync/resolution"
      assert_equal "old-hash-that-will-not-match", conflicted.content_hash,
        "content_hash must not be advanced while halted"
    end

    # ---------------------------------------------------------------------------
    # Step 2b — dirty-tracking (unchanged content → NO API call)
    # ---------------------------------------------------------------------------

    test "sync! skips the API call when content_hash is unchanged" do
      link_root_issue! # consistent topology: parent exported before child
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
      link_root_issue! # consistent topology: parent exported before child
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
      link_root_issue! # consistent topology: parent exported before child
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

    test "sync! omits parentId on update for the linked-root creative (parent outside Linear)" do
      # The ProjectLink-root creative's own parent is outside the linked subtree,
      # so no parentId must be sent (a nil/bogus parentId would error). This is
      # the legitimate "no linked parent" case — distinct from a child whose
      # in-subtree parent simply hasn't exported yet (which defers, below).
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @root_creative,
        project_link:    @project_link,
        linear_issue_id: "iss-root-self",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@root_creative).sync!
      end

      assert_equal 1, @fake_client.update_calls.size
      call = @fake_client.update_calls.first
      assert_not call.key?(:parent_id),
        "no parent_id must be sent when the parent is outside the linked subtree"
      existing_link.reload
      assert_not_equal "old-hash-that-will-not-match", existing_link.content_hash
    end

    test "sync! sends parentId: null on update when a creative moves out from under a linked parent to the project root" do
      # The link once recorded a linked Linear parent (parent_issue_id present),
      # but the creative now resolves NO linked parent (parent_linear_issue_id is
      # nil — its Collavre parent is outside the linked subtree / the project
      # root). Linear only changes provided fields, so omitting parentId would
      # leave the issue nested under its old parent while we persist
      # parent_issue_id: nil + synced — permanent, invisible hierarchy drift.
      # An explicit null must be sent to clear the remote parent.
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @root_creative,          # no Collavre parent -> parent_id nil
        project_link:    @project_link,
        linear_issue_id: "iss-was-nested",
        parent_issue_id: "iss-stale-parent",      # previously under a linked parent
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@root_creative).sync!
      end

      assert_equal 1, @fake_client.update_calls.size
      call = @fake_client.update_calls.first
      assert call.key?(:parent_id),
        "parentId must be sent (as null) to clear the remote parent on move-to-root"
      assert_nil call[:parent_id],
        "parentId must be an explicit null, not the stale parent"

      existing_link.reload
      assert_nil existing_link.parent_issue_id,
        "link parent_issue_id must be cleared to match the cleared remote parent"
    end

    test "sync! DEFERS an update when the parent is in-subtree but not yet exported" do
      # Codex fix: an already-linked creative moved under a NEWLY-created in-subtree
      # parent can run before the parent's create job. Exporting now would send no
      # parentId and record the wrong parent, and the parent export would NOT
      # re-enqueue this child. Defer (the job retries on ParentNotExportedError).
      new_parent = Collavre::Creative.new(
        description: "<p>New parent</p>", user: @user, parent: @root_creative
      )
      new_parent.skip_linear_sync = true
      new_parent.save!

      moved_child = Collavre::Creative.new(
        description: "<p>Moved child</p>", user: @user, parent: new_parent
      )
      moved_child.skip_linear_sync = true
      moved_child.save!

      # Child already has its own Linear issue (update path), but new_parent
      # has not exported yet.
      CollavreLinear::IssueLink.create!(
        creative:        moved_child,
        project_link:    @project_link,
        linear_issue_id: "iss-moved-child",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        assert_raises(CollavreLinear::CreativeExporter::ParentNotExportedError) do
          CollavreLinear::CreativeExporter.new(moved_child).sync!
        end
      end

      assert_equal 0, @fake_client.update_calls.size,
        "no update must be pushed while the new in-subtree parent is unexported"
    end

    # ---------------------------------------------------------------------------
    # Client::Error re-raise
    # ---------------------------------------------------------------------------

    test "sync! re-raises Client::Error so the job can retry" do
      link_root_issue!
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
      link_root_issue!
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
