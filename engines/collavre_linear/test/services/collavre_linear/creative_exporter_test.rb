# frozen_string_literal: true

require "test_helper"
require "digest"

module CollavreLinear
  class CreativeExporterTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    # ---------------------------------------------------------------------------
    # Plain stub — no network; conforms to Client's public interface.
    # ---------------------------------------------------------------------------
    class FakeClient
      attr_reader :create_calls, :update_calls, :fetch_state_calls

      def initialize(create_response: { id: "iss-new", identifier: "ENG-1" },
                     update_response: { id: "iss-new", identifier: "ENG-1" },
                     fetch_state_response: nil)
        @create_response       = create_response
        @update_response       = update_response
        @fetch_state_response  = fetch_state_response
        @create_calls          = []
        @update_calls          = []
        @fetch_state_calls     = []
      end

      def create_issue(**kwargs)
        @create_calls << kwargs
        @create_response
      end

      def update_issue(id, **kwargs)
        @update_calls << kwargs.merge(_id: id)
        @update_response
      end

      def fetch_issue_state(id)
        @fetch_state_calls << id
        @fetch_state_response
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

    # The ProjectLink-root creative maps to the Linear PROJECT, not an issue, so
    # it must never be exported. Exporting it would consume the project's single
    # top-level slot and flatten every sibling under it.
    test "sync! is a NO-OP for the ProjectLink-root creative (it maps to the project)" do
      CollavreLinear::Client.stub(:new, @fake_client) do
        result = CollavreLinear::CreativeExporter.new(@root_creative).sync!
        assert_nil result
      end

      assert_equal 0, @fake_client.create_calls.size,
        "the project-root creative must NOT create a Linear issue"
      assert_equal 0, @fake_client.update_calls.size
      assert_nil CollavreLinear::IssueLink.find_by(creative_id: @root_creative.id),
        "no IssueLink must be created for the project-root creative"
    end

    # A direct child of the project root is a TOP-LEVEL issue. The root has no
    # Linear issue (it IS the project), so the child exports with parentId nil
    # AND must NOT defer waiting for a parent issue that will never exist.
    test "sync! creates a TOP-LEVEL issue (no parentId) for a direct child of the project root" do
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 1, @fake_client.create_calls.size, "create_issue should be called once"

      call = @fake_client.create_calls.first
      assert_equal "team-exp",   call[:team_id]
      assert_equal "proj-exp",   call[:project_id]
      assert_nil call[:parent_id],
        "a direct child of the project root is a top-level issue (parentId nil)"
      assert_equal @child_creative.description, call[:description]

      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_nil link.parent_issue_id, "top-level issue link records no parent_issue_id"
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

    # Regression: the sync baseline (remote_updated_at) must be stamped from
    # LINEAR's returned updatedAt, not the app clock. The inbound applier compares
    # this baseline against a webhook's Linear-clock updatedAt to decide
    # conflict-vs-stale; an app-clock baseline (Time.current) can exceed a genuine
    # remote edit's Linear updatedAt (clock skew + round-trip latency) and drop it
    # as a "stale echo" — a silent lost update. Use a fixed, unmistakably-non-now
    # timestamp so a Time.current regression fails loudly.
    test "sync! baselines remote_updated_at on Linear's updatedAt after create" do
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
      # @child_creative has no ProjectLink; only @root_creative does. As a direct
      # child of the project root it exports as a top-level issue (no defer).
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      # Should have created an IssueLink under the ancestor's project.
      link = CollavreLinear::IssueLink.find_by(creative_id: @child_creative.id)
      assert_not_nil link
      assert_equal @project_link, link.project_link
    end

    test "sync! reconciles a self-echo race: adopts the inbound link and removes the duplicate" do
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

    test "sync! HALTS as conflict when the creative moved under a DIFFERENT linked project" do
      # The creative's IssueLink lives in project A, but it was reparented under a
      # different linked root (project B). resolve_project_link now returns B, so
      # updating would push A's issue with B's account/client (wrong project) and
      # silently diverge the tree from Linear. Reject: mark :conflict, no API call.
      # (Actively migrating/recreating in B is a product decision, out of scope.)
      other_root = Collavre::Creative.create!(description: "<p>Root B</p>", user: @user)
      other_link = CollavreLinear::ProjectLink.create!(
        creative: other_root, account: @account,
        linear_project_id: "proj-B", team_id: "team-B"
      )
      link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link, # project A
        linear_issue_id: "iss-cross",
        content_hash:    "hash-A",
        sync_state:      :synced
      )
      # Move the child under project B's root.
      @child_creative.skip_linear_sync = true
      @child_creative.update!(parent: other_root)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 0, @fake_client.update_calls.size,
        "must NOT update A's issue with B's client on a cross-project move"
      assert_equal 0, @fake_client.create_calls.size,
        "must NOT auto-recreate in B (that migration is a product decision)"
      assert_equal :conflict, link.reload.sync_state.to_sym
      assert CollavreLinear::ProjectLink.exists?(other_link.id),
        "project B remains linked (the move target)"
    end

    test "sync! DEFERS a new child whose parent's IssueLink is frozen in :conflict" do
      # A parent creative was halted mid cross-project move: its own IssueLink is
      # frozen at :conflict pointing at project A while it now sits under linked
      # root B. A brand-new child under it has NO IssueLink, so the cross-project
      # guard in sync! (which needs an existing link) never runs. Without this
      # defer, the child would be created in project B carrying a parentId from
      # project A's frozen issue — a wrong-project write Linear rejects or
      # mis-nests. Defer until the parent's conflict is resolved.
      other_root = Collavre::Creative.create!(description: "<p>Root B</p>", user: @user)
      CollavreLinear::ProjectLink.create!(
        creative: other_root, account: @account,
        linear_project_id: "proj-B", team_id: "team-B"
      )

      parent = Collavre::Creative.new(
        description: "<p>Conflicted parent</p>", user: @user, parent: other_root
      )
      parent.skip_linear_sync = true
      parent.save!
      CollavreLinear::IssueLink.create!(
        creative:        parent,
        project_link:    @project_link, # project A — different from B
        linear_issue_id: "iss-parent-A",
        content_hash:    "hash-parent",
        sync_state:      :conflict
      )

      child = Collavre::Creative.new(
        description: "<p>New child</p>", user: @user, parent: parent
      )
      child.skip_linear_sync = true
      child.save!

      assert_raises CollavreLinear::CreativeExporter::ParentNotExportedError do
        CollavreLinear::Client.stub(:new, @fake_client) do
          CollavreLinear::CreativeExporter.new(child).sync!
        end
      end

      assert_equal 0, @fake_client.create_calls.size,
        "must NOT create the child in B with a parentId from A's conflicted issue"
    end

    test "sync! backfills comments posted before the IssueLink existed" do
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      # Comment posted while the creative had no Linear issue yet: CommentSyncObserver
      # skipped it (syncable? requires a link) with no later backfill. skip_dispatch
      # avoids AI routing during the test.
      comment = @child_creative.comments.create!(
        content: "early comment", user: @user, skip_dispatch: true
      )

      assert_enqueued_with(job: CollavreLinear::OutboundCommentSyncJob, args: [ comment.id ]) do
        CollavreLinear::Client.stub(:new, @fake_client) do
          CollavreLinear::CreativeExporter.new(@child_creative).sync!
        end
      end
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
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
      # @child_creative starts as a TOP-LEVEL issue (direct child of the project
      # root). A SECOND top-level issue creative to move the child under, turning
      # it into a sub-issue.
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

      # The child already has an IssueLink whose content_hash reflects its
      # top-level state (parent = project root, no Linear parent).
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

    test "sync! does not add a spurious parentId change on a same-parent content edit (sub-issue)" do
      # A top-level issue creative (direct child of the project root) holds the
      # linked parent issue that the sub-issue below stays under.
      top = Collavre::Creative.new(
        description: "<p>Top</p>", user: @user, parent: @root_creative
      )
      top.skip_linear_sync = true
      top.save!
      CollavreLinear::IssueLink.create!(
        creative:        top,
        project_link:    @project_link,
        linear_issue_id: "iss-parent-stable",
        sync_state:      :synced
      )

      # A sub-issue creative under that top-level issue.
      sub = Collavre::Creative.new(
        description: "<p>Sub</p>", user: @user, parent: top
      )
      sub.skip_linear_sync = true
      sub.save!
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        sub,
        project_link:    @project_link,
        linear_issue_id: "iss-content-edit",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(sub).sync!
      end

      # Content changed → update runs. Because the parent is UNCHANGED (still the
      # linked top-level issue), parentId is still sent (idempotent — same value),
      # but the point is we don't fabricate a bogus/nil parentId that would error.
      assert_equal 1, @fake_client.update_calls.size
      call = @fake_client.update_calls.first
      assert_equal "iss-parent-stable", call[:parent_id],
        "the stable linked parent's id should be sent, not nil"
      existing_link.reload
      assert_not_equal "old-hash-that-will-not-match", existing_link.content_hash
    end

    test "sync! omits parentId on update for a top-level issue (parent is the project root, never a Linear issue)" do
      # A top-level issue's Collavre parent is the project root — which maps to
      # the Linear project, never an issue — and its link never recorded a
      # parent. No parentId must be sent (a nil/bogus parentId would error). This
      # is the legitimate "no linked parent" case — distinct from a child whose
      # in-subtree parent simply hasn't exported yet (which defers, below).
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,        # direct child of root = top-level issue
        project_link:    @project_link,
        linear_issue_id: "iss-top-self",
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal 1, @fake_client.update_calls.size
      call = @fake_client.update_calls.first
      assert_not call.key?(:parent_id),
        "no parent_id must be sent when the parent is the project root (no Linear issue)"
      existing_link.reload
      assert_not_equal "old-hash-that-will-not-match", existing_link.content_hash
    end

    test "sync! sends parentId: null on update when a creative moves out from under a linked parent to the project root" do
      # The link once recorded a linked Linear parent (parent_issue_id present),
      # but the creative now resolves NO linked parent (parent_linear_issue_id is
      # nil — its Collavre parent is the project root). Linear only changes
      # provided fields, so omitting parentId would leave the issue nested under
      # its old parent while we persist parent_issue_id: nil + synced —
      # permanent, invisible hierarchy drift. An explicit null must be sent to
      # clear the remote parent (promote the issue back to top-level).
      existing_link = CollavreLinear::IssueLink.create!(
        creative:        @child_creative,         # Collavre parent is the project root
        project_link:    @project_link,
        linear_issue_id: "iss-was-nested",
        parent_issue_id: "iss-stale-parent",      # previously under a linked parent
        content_hash:    "old-hash-that-will-not-match",
        sync_state:      :synced
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
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
    # Completion mapping (Collavre 100% → Linear done state)
    # ---------------------------------------------------------------------------

    test "sync! pushes the project's done_state_id as state_id for a leaf at 100%" do
      @project_link.update!(done_state_id: "state-done")
      # Leaf (no children) at 100%. update_column: set the raw progress without
      # tripping the parent rollup or the observer.
      @child_creative.update_column(:progress, 1.0)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.create_calls.first
      assert_equal "state-done", call[:state_id],
        "a completed leaf must export with the configured done workflow state"
    end

    test "sync! does NOT set a done state_id for a leaf below 100%" do
      @project_link.update!(done_state_id: "state-done")
      @child_creative.update_column(:progress, 0.5)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.create_calls.first
      assert_nil call[:state_id],
        "an incomplete leaf must not be forced into the done state"
    end

    test "sync! does NOT set a done state_id for a NON-leaf creative even at 100%" do
      @project_link.update!(done_state_id: "state-done")
      # Give @child_creative a child so it is no longer a leaf. Its own progress
      # would be a rollup; force it to 1.0 to prove leaf-ness (not the value) gates.
      grandchild = Collavre::Creative.new(
        description: "<p>Grandchild</p>", user: @user, parent: @child_creative
      )
      grandchild.skip_linear_sync = true
      grandchild.save!
      @child_creative.update_column(:progress, 1.0)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.create_calls.first
      assert_nil call[:state_id],
        "only leaves drive the done state; a parent's rolled-up 100% must not"
    end

    test "sync! ignores completion when the project link has no done_state_id" do
      @child_creative.update_column(:progress, 1.0) # done_state_id nil (default)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.create_calls.first
      assert_nil call[:state_id],
        "completion mapping is off until a done state is configured"
    end

    test "content_hash_for folds in the completion state so completing a leaf changes the hash" do
      @project_link.update!(done_state_id: "state-done")

      @child_creative.update_column(:progress, 0.0)
      incomplete_hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative.reload)

      @child_creative.update_column(:progress, 1.0)
      complete_hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative.reload)

      assert_not_equal incomplete_hash, complete_hash,
        "the content hash must change when a leaf reaches 100% so the exporter pushes"
    end

    # ---------------------------------------------------------------------------
    # Completion mapping — outbound un-done (restore pre-done state)
    # ---------------------------------------------------------------------------

    # Give @child_creative an existing Linear issue so sync! takes the update path.
    def link_child_issue!(content_hash: "stale-hash", linear_issue_id: "iss-child")
      CollavreLinear::IssueLink.create!(
        creative:        @child_creative,
        project_link:    @project_link,
        linear_issue_id: linear_issue_id,
        content_hash:    content_hash,
        sync_state:      :synced
      )
    end

    test "sync! captures the last-known pre-done state when a leaf reaches 100%" do
      @project_link.update!(done_state_id: "state-done")
      link_child_issue!
      @child_creative.update_column(
        :data, { "linear" => { "state" => { "id" => "state-todo", "name" => "Todo" } } }
      )
      @child_creative.update_column(:progress, 1.0)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.update_calls.first
      assert_equal "state-done", call[:state_id], "a completed leaf still pushes the done state"
      assert_equal({ "id" => "state-todo", "name" => "Todo" },
        @child_creative.reload.data.dig("linear", "state_before_done"),
        "the state the leaf left must be snapshotted so a later un-done can restore it")
    end

    test "sync! queries Linear ONCE for the current state when none is locally known before pushing done" do
      @project_link.update!(done_state_id: "state-done")
      link_child_issue!(linear_issue_id: "iss-x")
      # No data["linear"]["state"] — the leaf reached 100% purely in Collavre.
      @child_creative.update_column(:progress, 1.0)
      @fake_client = FakeClient.new(fetch_state_response: { "id" => "state-backlog", "name" => "Backlog" })

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      assert_equal [ "iss-x" ], @fake_client.fetch_state_calls,
        "with no locally-known state, the exporter queries Linear once to seed the snapshot"
      assert_equal({ "id" => "state-backlog", "name" => "Backlog" },
        @child_creative.reload.data.dig("linear", "state_before_done"),
        "the queried current state is stored as the pre-done snapshot")
      assert_equal "state-done", @fake_client.update_calls.first[:state_id]
    end

    test "sync! restores the captured pre-done state when a completed leaf drops below 100%" do
      @project_link.update!(done_state_id: "state-done")
      link_child_issue!
      # Our record shows the issue sitting in done (the echo landed) with a snapshot.
      @child_creative.update_column(:data, { "linear" => {
        "state"             => { "id" => "state-done", "name" => "Done" },
        "state_before_done" => { "id" => "state-todo", "name" => "Todo" }
      } })
      @child_creative.update_column(:progress, 0.5)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.update_calls.first
      assert_equal "state-todo", call[:state_id],
        "a leaf dropped below 100% while shown as done must be restored to its pre-done state"
    end

    test "sync! does NOT restore (fight a human move) when the issue is no longer in the done state" do
      @project_link.update!(done_state_id: "state-done")
      link_child_issue!
      # A human moved the issue to In Progress in Linear; a stale snapshot lingers.
      @child_creative.update_column(:data, { "linear" => {
        "state"             => { "id" => "state-inprogress", "name" => "In Progress" },
        "state_before_done" => { "id" => "state-todo", "name" => "Todo" }
      } })
      @child_creative.update_column(:progress, 0.5)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      call = @fake_client.update_calls.first
      assert_equal "state-inprogress", call[:state_id],
        "once the issue has left the done state, the natural mapped state applies — no restore override"
    end

    test "content_hash_for reflects the restore override so inbound and outbound agree" do
      @project_link.update!(done_state_id: "state-done")
      @child_creative.update_column(:progress, 0.5)

      @child_creative.update_column(:data, { "linear" => {
        "state" => { "id" => "state-done" }
      } })
      no_snapshot_hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative.reload)

      @child_creative.update_column(:data, { "linear" => {
        "state"             => { "id" => "state-done" },
        "state_before_done" => { "id" => "state-todo" }
      } })
      restored_hash = CollavreLinear::CreativeExporter.content_hash_for(@child_creative.reload)

      assert_not_equal no_snapshot_hash, restored_hash,
        "the pure hash must fold in the restored pre-done state so an inbound apply advances it consistently"
    end

    # END-TO-END un-done: mirrors the REAL pure-outbound flow — a leaf completed
    # in Collavre (no prior inbound state, our done-push echo is suppressed so
    # data["linear"]["state"] is NEVER set to done), then dropped below 100%.
    # The earlier restore tests fake data["linear"]["state"] == done; this one
    # does NOT, so it exercises the actual capture→restore handoff.
    test "sync! restores pre-done state on drop after a real Collavre-driven completion (no faked echo)" do
      @project_link.update!(done_state_id: "state-done")
      link_child_issue!(linear_issue_id: "iss-x")
      # Leaf reached 100% purely in Collavre: no data["linear"]["state"] at all.
      @child_creative.update_column(:progress, 1.0)
      @fake_client = FakeClient.new(fetch_state_response: { "id" => "state-backlog", "name" => "Backlog" })

      # Step 1: push done (captures the pre-done state via a one-time Linear query).
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end
      assert_equal "state-done", @fake_client.update_calls.first[:state_id],
        "precondition: completing the leaf pushes done"

      # Step 2: drop below 100% — Linear must be restored to the captured state.
      @child_creative.reload.update_column(:progress, 0.0)
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::CreativeExporter.new(@child_creative).sync!
      end

      restore_call = @fake_client.update_calls.last
      assert_equal "state-backlog", restore_call[:state_id],
        "dropping a Collavre-completed leaf below 100% must restore the pre-done Linear state"
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
