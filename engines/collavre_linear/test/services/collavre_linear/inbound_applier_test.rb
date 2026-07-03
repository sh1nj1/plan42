# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  # Task 10 — Linear inbound → Creative CRUD applier.
  #
  # `InboundApplier` accepts a PARSED payload hash (string keys) exactly as the
  # WebhooksController / InboundApplyJob hand it over, and mutates local Collavre
  # state (Creatives, IssueLinks, CommentLinks) accordingly.
  class InboundApplierTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    def setup
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "inbound-test-#{SecureRandom.hex(4)}@example.com",
        name: "Inbound Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-inb-#{SecureRandom.hex(4)}",
        access_token: "tok-inb"
      )

      @root_creative = Collavre::Creative.new(description: "<p>Root</p>", user: @user)
      @root_creative.skip_linear_sync = true
      @root_creative.save!

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @root_creative,
        account:  @account,
        linear_project_id: "proj-inb",
        team_id:           "team-inb"
      )
    end

    def teardown
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # -- helpers ---------------------------------------------------------------

    def linked_child(linear_issue_id: "iss-1", **link_attrs)
      creative = Collavre::Creative.new(
        description: "<p>Original title</p>",
        user: @user,
        parent: @root_creative
      )
      creative.skip_linear_sync = true
      creative.save!

      link = CollavreLinear::IssueLink.create!(
        creative:          creative,
        project_link:      @project_link,
        linear_issue_id:   linear_issue_id,
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced,
        **link_attrs
      )
      [ creative, link ]
    end

    # -- Step 1: update applies fields WITHOUT enqueuing an outbound job -------

    test "update applies new title to the linked creative and does NOT enqueue outbound sync" do
      creative, _link = linked_child(linear_issue_id: "iss-upd")

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-upd",
          "title"     => "Updated title",
          "priority"  => 2,
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "title" => "Original title" }
      }

      assert_no_enqueued_jobs(only: CollavreLinear::OutboundSyncJob) do
        CollavreLinear::InboundApplier.new(payload).apply!
      end

      creative.reload
      assert_includes creative.description, "Updated title",
        "linked creative description should reflect the inbound title"
    end

    test "update writes sequence via the model (priority 1 => sequence 0)" do
      creative, _link = linked_child(linear_issue_id: "iss-seq")

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-seq",
          "title"     => "Seq",
          "priority"  => 1,
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "priority" => 3 }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_equal 0, creative.reload.sequence,
        "priority 1 (Urgent) should map to zero-based sequence 0 (first sibling)"
    end

    test "update advances IssueLink#content_hash to the newly-applied state" do
      creative, link = linked_child(linear_issue_id: "iss-hash")
      link.update!(content_hash: "stale-outbound-hash", sync_state: :synced)

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-hash",
          "title"     => "Remote new title",
          "priority"  => 2,
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "title" => "Original title" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      link.reload
      creative.reload
      expected = CollavreLinear::CreativeExporter.content_hash_for(creative)
      assert_equal expected, link.content_hash,
        "content_hash should match the freshly-applied creative state"
      assert_equal "synced", link.sync_state
      assert_not_equal "stale-outbound-hash", link.content_hash
    end

    test "a no-op export after inbound update is correctly skipped (hash matches)" do
      creative, link = linked_child(linear_issue_id: "iss-noop")

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-noop",
          "title"     => "Synced title",
          "priority"  => 3,
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "title" => "Original title" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      # Simulate the exporter's dirty-check: current creative content hashes to
      # exactly what the link stores, so update_issue! would skip the API call.
      creative.reload
      current_hash = CollavreLinear::CreativeExporter.content_hash_for(creative)
      assert_equal link.reload.content_hash, current_hash
    end

    # -- update: reparent ------------------------------------------------------

    test "update with a changed parentId moves the creative under the new linked parent" do
      # Two linked potential parents plus the child currently under parent A.
      parent_a, _link_a = linked_child(linear_issue_id: "iss-parent-a")
      parent_b, _link_b = linked_child(linear_issue_id: "iss-parent-b")

      child = Collavre::Creative.new(
        description: "<p>Child</p>", user: @user, parent: parent_a
      )
      child.skip_linear_sync = true
      child.save!
      child_link = CollavreLinear::IssueLink.create!(
        creative:          child,
        project_link:      @project_link,
        linear_issue_id:   "iss-child",
        parent_issue_id:   "iss-parent-a",
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced
      )

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-child",
          "title"     => "Child",
          "parentId"  => "iss-parent-b",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "parentId" => "iss-parent-a" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      child.reload
      child_link.reload
      assert_equal parent_b.id, child.parent_id,
        "creative should be reparented under the new linked parent"
      assert_equal "iss-parent-b", child_link.parent_issue_id,
        "link.parent_issue_id should track the new Linear parent"

      # The content hash folds in the parent's linear_issue_id, so it must reflect
      # the NEW parent — otherwise later outbound syncs would treat the old parent
      # as synced and hide the divergence.
      expected = CollavreLinear::CreativeExporter.content_hash_for(child)
      assert_equal expected, child_link.content_hash
    end

    test "update to a not-yet-linked parentId records the new id but does not move to a bogus node" do
      parent_a, _link_a = linked_child(linear_issue_id: "iss-p-a")

      child = Collavre::Creative.new(
        description: "<p>Child</p>", user: @user, parent: parent_a
      )
      child.skip_linear_sync = true
      child.save!
      child_link = CollavreLinear::IssueLink.create!(
        creative:          child,
        project_link:      @project_link,
        linear_issue_id:   "iss-c",
        parent_issue_id:   "iss-p-a",
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced
      )

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-c",
          "title"     => "Child",
          "parentId"  => "iss-parent-later",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "parentId" => "iss-p-a" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      child.reload
      child_link.reload
      assert_equal parent_a.id, child.parent_id,
        "creative must not move when the new Linear parent isn't linked locally yet"
      # The NEW parent_issue_id must be recorded so reparent_pending_children! can
      # move the child once the parent's create webhook arrives. Recording the OLD
      # id (the previous buggy behavior) would strand the child forever.
      assert_equal "iss-parent-later", child_link.parent_issue_id,
        "the new parent_issue_id must be recorded for later repair"
    end

    test "a move under a not-yet-created parent is repaired when the parent create arrives" do
      parent_a, _link_a = linked_child(linear_issue_id: "iss-move-a")

      child = Collavre::Creative.new(
        description: "<p>Child</p>", user: @user, parent: parent_a
      )
      child.skip_linear_sync = true
      child.save!
      CollavreLinear::IssueLink.create!(
        creative:          child,
        project_link:      @project_link,
        linear_issue_id:   "iss-move-child",
        parent_issue_id:   "iss-move-a",
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced
      )

      # 1) The move update arrives BEFORE the new parent's create webhook.
      CollavreLinear::InboundApplier.new(
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-move-child",
          "title"     => "Child",
          "parentId"  => "iss-move-new-parent",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "parentId" => "iss-move-a" }
      ).apply!

      # 2) The new parent's create webhook lands and must repair the hierarchy.
      CollavreLinear::InboundApplier.new(
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-move-new-parent",
          "title"     => "New Parent",
          "projectId" => "proj-inb",
          "updatedAt" => Time.current.iso8601
        }
      ).apply!

      new_parent = CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-move-new-parent").creative
      assert_equal new_parent.id, child.reload.parent_id,
        "child must be reparented under the new parent once its create lands"
    end

    test "a move to a DIFFERENT linked project surfaces a conflict instead of silently syncing" do
      creative, link = linked_child(linear_issue_id: "iss-xproj")

      # A second linked project (a different Collavre root) — the move target.
      other_root = Collavre::Creative.new(description: "<p>Other root</p>", user: @user)
      other_root.skip_linear_sync = true
      other_root.save!
      CollavreLinear::ProjectLink.create!(
        creative:          other_root,
        account:           @account,
        linear_project_id: "proj-inb-b",
        team_id:           "team-inb"
      )

      CollavreLinear::InboundApplier.new(
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-xproj",
          "title"     => "Moved",
          "projectId" => "proj-inb-b",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "projectId" => "proj-inb" }
      ).apply!

      link.reload
      # The mapping is now provably wrong (Creative under root A, Linear says
      # project B). Auto-applying + marking :synced would freeze that drift and
      # future outbound syncs would push against the old project's account.
      assert link.conflict?,
        "cross-project move must be surfaced as a conflict, not marked synced"
      assert_equal @root_creative.id, creative.reload.parent_id,
        "the creative must not be silently re-homed on a cross-project move"
    end

    test "a move to an UNLINKED project also surfaces a conflict (no silent drift)" do
      creative, link = linked_child(linear_issue_id: "iss-xproj-unlinked")

      CollavreLinear::InboundApplier.new(
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-xproj-unlinked",
          "title"     => "Moved out",
          "projectId" => "proj-not-linked",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "projectId" => "proj-inb" }
      ).apply!

      link.reload
      assert link.conflict?,
        "moving an issue out to an unlinked project must surface, not silently sync"
      assert_includes creative.reload.description, "Original title",
        "no field updates should be applied on an un-appliable cross-project move"
    end

    test "inbound reparent does not enqueue an outbound sync (echo suppressed)" do
      parent_a, _la = linked_child(linear_issue_id: "iss-echo-a")
      parent_b, _lb = linked_child(linear_issue_id: "iss-echo-b")

      child = Collavre::Creative.new(
        description: "<p>Child</p>", user: @user, parent: parent_a
      )
      child.skip_linear_sync = true
      child.save!
      CollavreLinear::IssueLink.create!(
        creative:          child,
        project_link:      @project_link,
        linear_issue_id:   "iss-echo-child",
        parent_issue_id:   "iss-echo-a",
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced
      )

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-echo-child",
          "title"     => "Child",
          "parentId"  => "iss-echo-b",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "parentId" => "iss-echo-a" }
      }

      assert_no_enqueued_jobs only: CollavreLinear::OutboundSyncJob do
        CollavreLinear::InboundApplier.new(payload).apply!
      end
      assert_equal parent_b.id, child.reload.parent_id
    end

    # -- create ----------------------------------------------------------------

    test "create builds a child creative under the project root and an IssueLink" do
      payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-new",
          "title"     => "Brand new issue",
          "priority"  => 0,
          "projectId" => "proj-inb",
          "updatedAt" => Time.current.iso8601
        }
      }

      assert_difference -> { CollavreLinear::IssueLink.count }, 1 do
        CollavreLinear::InboundApplier.new(payload).apply!
      end

      link = CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-new")
      assert_not_nil link
      assert_equal @root_creative.id, link.creative.parent_id,
        "new creative should be a child of the project root creative"
      assert_includes link.creative.description, "Brand new issue"
    end

    test "create nests under the parent issue's creative when parent is linked" do
      parent_creative, _plink = linked_child(linear_issue_id: "iss-parent")

      payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"       => "iss-child",
          "title"    => "Sub-issue",
          "priority" => 0,
          "parentId" => "iss-parent",
          "updatedAt" => Time.current.iso8601
        }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      link = CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-child")
      assert_equal parent_creative.id, link.creative.parent_id,
        "child issue should nest under the parent issue's creative"
    end

    test "out-of-order create (child before parent) reparents the child once the parent lands" do
      # Child arrives first: parent not linked yet, so it falls back to root but
      # records parent_issue_id.
      child_payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-ooo-child",
          "title"     => "Early child",
          "priority"  => 0,
          "parentId"  => "iss-ooo-parent",
          "projectId" => "proj-inb",
          "updatedAt" => Time.current.iso8601
        }
      }
      CollavreLinear::InboundApplier.new(child_payload).apply!

      child_link = CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-ooo-child")
      assert_equal @root_creative.id, child_link.creative.parent_id,
        "child with an unknown parent falls back to the project root"

      # Parent arrives later: the child must be reparented under it.
      parent_payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-ooo-parent",
          "title"     => "Late parent",
          "priority"  => 0,
          "projectId" => "proj-inb",
          "updatedAt" => Time.current.iso8601
        }
      }
      CollavreLinear::InboundApplier.new(parent_payload).apply!

      parent_link = CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-ooo-parent")
      assert_equal parent_link.creative.id, child_link.reload.creative.parent_id,
        "child must be reparented under the parent once the parent create lands"
    end

    test "a Project webhook is ignored (no blank Creative/IssueLink created)" do
      # The webhook subscribes to Project events; routing them as Issues would
      # use the project UUID as linear_issue_id and create a blank Creative.
      payload = {
        "action" => "create",
        "type"   => "Project",
        "data"   => { "id" => "proj-inb", "name" => "A project", "updatedAt" => Time.current.iso8601 }
      }

      assert_no_difference [ -> { CollavreLinear::IssueLink.count },
                            -> { Collavre::Creative.count } ] do
        CollavreLinear::InboundApplier.new(payload).apply!
      end
    end

    # -- remove: archive marker, no destroy/reparent ---------------------------

    test "remove sets an archive marker and does not destroy the creative" do
      creative, link = linked_child(linear_issue_id: "iss-rm")
      child = Collavre::Creative.new(description: "<p>grandchild</p>", user: @user, parent: creative)
      child.skip_linear_sync = true
      child.save!

      payload = {
        "action" => "remove",
        "type"   => "Issue",
        "data"   => { "id" => "iss-rm", "updatedAt" => Time.current.iso8601 }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert Collavre::Creative.exists?(creative.id), "creative must not be destroyed"
      assert Collavre::Creative.exists?(child.id), "children must not be reparented/destroyed"
      creative.reload
      assert_equal true, creative.data.dig("linear", "archived"),
        "archived marker should be set in data['linear']['archived']"
      assert_not_nil link.reload.sync_state, "issue link sync_state should be marked"
    end

    # -- comment ---------------------------------------------------------------

    test "comment create adds a Collavre comment and a CommentLink" do
      creative, _link = linked_child(linear_issue_id: "iss-cmt")

      payload = {
        "action" => "create",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-1",
          "body"  => "A linear comment",
          "issue" => { "id" => "iss-cmt" },
          "updatedAt" => Time.current.iso8601
        }
      }

      assert_difference -> { CollavreLinear::CommentLink.count }, 1 do
        assert_difference -> { creative.comments.count }, 1 do
          CollavreLinear::InboundApplier.new(payload).apply!
        end
      end

      link = CollavreLinear::CommentLink.find_by(linear_comment_id: "cmt-1")
      assert_not_nil link
      assert_equal "A linear comment", Collavre::Comment.find(link.comment_id).content
    end

    test "comment create is attributed to the issue's account owner with multiple linked projects" do
      # Second linked project (different account/owner) so ProjectLink.count > 1
      # — the comment payload carries no projectId/parentId, so the sole-link
      # fallback returns nil and would drop author attribution. The correct owner
      # is reachable via the resolved issue_link's project_link.
      other_user = Collavre.user_class.create!(
        email: "inbound-other-#{SecureRandom.hex(4)}@example.com",
        name: "Inbound Other",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      other_account = CollavreLinear::Account.create!(
        user: other_user,
        linear_uid: "uid-inb-other-#{SecureRandom.hex(4)}",
        access_token: "tok-inb-other"
      )
      other_root = Collavre::Creative.new(description: "<p>Other Root</p>", user: other_user)
      other_root.skip_linear_sync = true
      other_root.save!
      CollavreLinear::ProjectLink.create!(
        creative: other_root,
        account:  other_account,
        linear_project_id: "proj-inb-other",
        team_id:           "team-inb-other"
      )
      assert_operator CollavreLinear::ProjectLink.count, :>, 1

      _creative, _link = linked_child(linear_issue_id: "iss-cmt-multi")

      payload = {
        "action" => "create",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-multi",
          "body"  => "A comment in a multi-project install",
          "issue" => { "id" => "iss-cmt-multi" },
          "updatedAt" => Time.current.iso8601
        }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      link = CollavreLinear::CommentLink.find_by(linear_comment_id: "cmt-multi")
      assert_not_nil link
      comment = Collavre::Comment.find(link.comment_id)
      assert_not_nil comment.user, "inbound comment must not lose author attribution"
      assert_equal @user.id, comment.user_id,
        "comment must be attributed to the issue's account owner, not nil or another project's owner"
    end

    test "comment update edits the existing Collavre comment" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt2")
      comment = creative.comments.create!(content: "old body", user: @user, skip_dispatch: true)
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-2",
        issue_link: issue_link
      )

      payload = {
        "action" => "update",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-2",
          "body"  => "edited body",
          "issue" => { "id" => "iss-cmt2" },
          "updatedAt" => Time.current.iso8601
        }
      }

      assert_no_difference -> { CollavreLinear::CommentLink.count } do
        CollavreLinear::InboundApplier.new(payload).apply!
      end

      assert_equal "edited body", comment.reload.content
    end

    test "comment update ignores our own echo so the name prefix is not injected locally" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-echo")
      comment = creative.comments.create!(content: "hello", user: @user, skip_dispatch: true)
      # Outbound stored Linear's updatedAt for the version we posted; the echo
      # carries that same timestamp, so it is not strictly newer -> skipped.
      synced_at = Time.current
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-echo",
        issue_link: issue_link,
        remote_updated_at: synced_at
      )

      # Linear echoes back the prefixed body the outbound job sent.
      echoed_body = CollavreLinear::CommentFormatter.outbound_body(comment)
      payload = {
        "action" => "update",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-echo",
          "body"  => echoed_body,
          "issue" => { "id" => "iss-cmt-echo" },
          "updatedAt" => synced_at.iso8601
        }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_equal "hello", comment.reload.content,
        "the echo of our own prefixed comment must not overwrite the canonical local body"
    end

    test "a stale echo of an older body does not overwrite a newer local edit" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-stale")
      # The user already re-edited the comment to B locally; the outbound update
      # advanced the synced baseline to that edit's Linear updatedAt.
      comment = creative.comments.create!(content: "B newer local edit", user: @user, skip_dispatch: true)
      baseline = Time.current
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-stale",
        issue_link: issue_link,
        remote_updated_at: baseline
      )

      # Linear now delivers the delayed echo of the ORIGINAL A version, whose
      # updatedAt predates the baseline. A mutable-content comparison would treat
      # it as a genuine edit and clobber B; the timestamp guard skips it.
      payload = {
        "action" => "update",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-stale",
          "body"  => "\\[name\\]: A stale old body",
          "issue" => { "id" => "iss-cmt-stale" },
          "updatedAt" => (baseline - 30.seconds).iso8601
        }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_equal "B newer local edit", comment.reload.content,
        "a stale echo (older updatedAt) must not clobber the newer local edit"
    end

    test "an echo racing ahead of the outbound baseline commit is suppressed once the lock exposes it" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-race")
      comment = creative.comments.create!(content: "hello", user: @user, skip_dispatch: true)
      # The link still carries the PRE-outbound baseline: the outbound update job is
      # in-flight (holding the lock), has already reached Linear, but has not yet
      # committed the new remote_updated_at. Reading this stale value would classify
      # our own echo as a genuine Linear edit.
      committed_at = Time.current
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-race",
        issue_link: issue_link,
        remote_updated_at: committed_at - 1.hour
      )

      # Simulate the outbound job committing its baseline the instant the inbound
      # apply acquires the lock — i.e. the echo raced in first, and the lock makes
      # the apply wait until the outbound commit is visible. The module always
      # `super`s and only acts for this one link, so it does not affect other tests.
      race = Module.new do
        define_method(:with_lock) do |*args, &blk|
          if linear_comment_id == "cmt-race" && !@_committed
            @_committed = true
            self.class.where(id: id).update_all(remote_updated_at: committed_at)
          end
          super(*args, &blk)
        end
      end
      CollavreLinear::CommentLink.prepend(race)

      # Echo of our own outbound edit: updatedAt == the baseline the outbound commits.
      payload = {
        "action" => "update",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-race",
          "body"  => CollavreLinear::CommentFormatter.outbound_body(comment),
          "issue" => { "id" => "iss-cmt-race" },
          "updatedAt" => committed_at.iso8601
        }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_equal "hello", comment.reload.content,
        "an echo that arrived before the outbound baseline commit must be suppressed " \
        "once the CommentLink lock exposes the committed baseline (no lock -> clobber)"
    end

    test "comment remove deletes the mirrored comment and its CommentLink" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-rm")
      comment = creative.comments.create!(content: "to be removed", user: @user, skip_dispatch: true)
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-rm",
        issue_link: issue_link
      )

      payload = {
        "action" => "remove",
        "type"   => "Comment",
        "data"   => { "id" => "cmt-rm", "issue" => { "id" => "iss-cmt-rm" } }
      }

      assert_difference -> { CollavreLinear::CommentLink.count }, -1 do
        CollavreLinear::InboundApplier.new(payload).apply!
      end

      refute Collavre::Comment.exists?(comment.id),
        "the mirrored comment must be deleted, not blanked"
    end

    test "comment remove for an unlinked comment is a no-op (no blank comment created)" do
      creative, _link = linked_child(linear_issue_id: "iss-cmt-rm2")

      payload = {
        "action" => "remove",
        "type"   => "Comment",
        "data"   => { "id" => "cmt-never-linked", "issue" => { "id" => "iss-cmt-rm2" } }
      }

      assert_no_difference -> { creative.comments.count } do
        assert_no_difference -> { CollavreLinear::CommentLink.count } do
          CollavreLinear::InboundApplier.new(payload).apply!
        end
      end
    end

    test "genuine inbound comment edit applies locally but does NOT echo an outbound update" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-noecho")
      comment = creative.comments.create!(content: "old body", user: @user, skip_dispatch: true)
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-noecho",
        issue_link: issue_link,
        remote_updated_at: 1.hour.ago
      )

      payload = {
        "action" => "update",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-noecho",
          "body"  => "a real linear-side edit",
          "issue" => { "id" => "iss-cmt-noecho" },
          "updatedAt" => Time.current.iso8601
        }
      }

      # The local edit must land, but re-emitting it to Linear would loop the
      # author-name prefix back into itself (double-prefix); the applier flags the
      # comment skip_linear_sync so the CommentSyncObserver stays silent.
      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentUpdateJob do
        CollavreLinear::InboundApplier.new(payload).apply!
      end
      assert_equal "a real linear-side edit", comment.reload.content
    end

    test "inbound comment remove deletes locally but does NOT echo an outbound delete" do
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-rmnoecho")
      comment = creative.comments.create!(content: "bye", user: @user, skip_dispatch: true)
      CollavreLinear::CommentLink.create!(
        comment_id: comment.id,
        linear_comment_id: "cmt-rmnoecho",
        issue_link: issue_link
      )

      payload = {
        "action" => "remove",
        "type"   => "Comment",
        "data"   => { "id" => "cmt-rmnoecho", "issue" => { "id" => "iss-cmt-rmnoecho" } }
      }

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentDeleteJob do
        CollavreLinear::InboundApplier.new(payload).apply!
      end
      refute Collavre::Comment.exists?(comment.id)
    end

    test "losing a comment-create race leaves NO orphan comment (unique violation past the guard)" do
      # Pre-create a CommentLink for the same linear_comment_id to guarantee the
      # unique insert fails. Bypass the early find_by guard (stub it to nil) so
      # the applier proceeds to create a Collavre::Comment and then hits the
      # unique linear_comment_id — the exact TOCTOU window. The comment+link must
      # be atomic so the loser leaves no orphan (unlinked) comment behind.
      creative, issue_link = linked_child(linear_issue_id: "iss-cmt-race")
      winner = creative.comments.create!(content: "winner", user: @user, skip_dispatch: true)
      CollavreLinear::CommentLink.create!(
        comment_id: winner.id,
        linear_comment_id: "cmt-race",
        issue_link: issue_link
      )

      payload = {
        "action" => "create",
        "type"   => "Comment",
        "data"   => {
          "id"    => "cmt-race",
          "body"  => "loser duplicate",
          "issue" => { "id" => "iss-cmt-race" },
          "updatedAt" => Time.current.iso8601
        }
      }

      comment_count_before = creative.comments.count

      CollavreLinear::CommentLink.stub :find_by, nil do
        assert_nothing_raised do
          CollavreLinear::InboundApplier.new(payload).apply!
        end
      end

      assert_equal comment_count_before, creative.reload.comments.count,
        "the losing comment-create must not leave an orphan comment"
      assert_equal 1, CollavreLinear::CommentLink.where(linear_comment_id: "cmt-race").count
    end

    # -- Step 4: conflict ------------------------------------------------------

    test "already-conflicted link skips a later inbound update (no clobber, stays conflict)" do
      creative, link = linked_child(linear_issue_id: "iss-conf-skip")
      link.update!(sync_state: :conflict, remote_updated_at: 1.hour.ago)
      original = creative.description

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-conf-skip",
          "title"     => "Remote overwrite attempt",
          "priority"  => 2,
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "title" => "x" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_equal "conflict", link.reload.sync_state.to_s,
        "an already-conflicted link must remain conflicted (halt until resolution)"
      assert_equal original, creative.reload.description,
        "a conflicted link must not be overwritten by a later remote update"
    end

    test "dirty link + newer remote => conflict, comment posted in Main topic, fields unchanged" do
      creative, link = linked_child(linear_issue_id: "iss-conf")
      link.update!(sync_state: :dirty, remote_updated_at: 2.hours.ago)
      original_description = creative.reload.description

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-conf",
          "title"     => "Remote wins?",
          "priority"  => 2,
          "updatedAt" => Time.current.iso8601   # newer than remote_updated_at (2h ago)
        },
        "updatedFrom" => { "title" => "x" }
      }

      assert_difference -> { creative.comments.count }, 1 do
        CollavreLinear::InboundApplier.new(payload).apply!
      end

      assert_equal "conflict", link.reload.sync_state.to_s
      assert_equal original_description, creative.reload.description,
        "on conflict the field apply must be skipped (no data loss)"

      # Fix 1: conflict comment must land in the Main topic, not System.
      conflict_comment = creative.comments.order(created_at: :desc).first
      main_topic = creative.main_topic(fallback_user: @user)
      assert_equal main_topic.id, conflict_comment.topic_id,
        "conflict comment must be posted to the Main topic, not a System topic"
    end

    # -- Fix 2: TOCTOU — duplicate inbound create is idempotent ------------------

    test "applying the same Issue create twice yields exactly one Creative and one IssueLink" do
      payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-dup",
          "title"     => "Duplicate create test",
          "priority"  => 0,
          "projectId" => "proj-inb",
          "updatedAt" => Time.current.iso8601
        }
      }

      assert_nothing_raised do
        CollavreLinear::InboundApplier.new(payload).apply!
        # Simulate a concurrent webhook: apply the same payload a second time.
        CollavreLinear::InboundApplier.new(payload).apply!
      end

      assert_equal 1, CollavreLinear::IssueLink.where(linear_issue_id: "iss-dup").count,
        "duplicate inbound create must not create a second IssueLink"
      dup_link = CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-dup")
      assert_not_nil dup_link
      assert_equal 1,
        Collavre::Creative.where(id: dup_link.creative_id).count,
        "duplicate inbound create must not create a second Creative"
    end

    test "losing a create race (unique violation past the guard) leaves NO orphan Creative" do
      # Pre-create a link for the same linear_issue_id to guarantee the unique
      # insert fails. Bypass the early find_by guard (stub it to nil) so the
      # applier proceeds to save a Creative and then hits RecordNotUnique on the
      # IssueLink insert — the exact TOCTOU window.
      existing_creative, _existing_link = linked_child(linear_issue_id: "iss-race")

      payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-race",
          "title"     => "Race loser",
          "priority"  => 0,
          "projectId" => "proj-inb",
          "updatedAt" => Time.current.iso8601
        }
      }

      creative_count_before = Collavre::Creative.count

      CollavreLinear::IssueLink.stub :find_by, nil do
        assert_nothing_raised do
          CollavreLinear::InboundApplier.new(payload).apply!
        end
      end

      assert_equal creative_count_before, Collavre::Creative.count,
        "the losing create must not leave an orphan Creative"
      assert_equal 1, CollavreLinear::IssueLink.where(linear_issue_id: "iss-race").count
      # The surviving link still points at the original creative.
      assert_equal existing_creative.id,
        CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-race").creative_id
    end

    # -- Fix 3: nil remote_updated_at must NOT produce a false conflict ----------

    test "dirty link with nil remote_updated_at allows inbound apply (no spurious conflict)" do
      creative, link = linked_child(linear_issue_id: "iss-nilbase")
      # Simulate a freshly-dirty link with no remote baseline.
      link.update!(sync_state: :dirty, remote_updated_at: nil)

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-nilbase",
          "title"     => "Should apply",
          "priority"  => 2,
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "title" => "x" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_not_equal "conflict", link.reload.sync_state.to_s,
        "dirty link with nil remote_updated_at must not be treated as a conflict"
      assert_includes creative.reload.description, "Should apply",
        "inbound apply must proceed when remote_updated_at baseline is nil"
    end

    test "dirty link + older remote => stale echo, no-op (keeps local edit, stays dirty)" do
      creative, link = linked_child(linear_issue_id: "iss-noconf")
      baseline = Time.current
      link.update!(sync_state: :dirty, remote_updated_at: baseline)
      local_description = creative.reload.description

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-noconf",
          "title"     => "Older remote",
          "priority"  => 2,
          "updatedAt" => 1.hour.ago.iso8601   # older than baseline (now)
        },
        "updatedFrom" => { "title" => "x" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      # An older-than-baseline payload on a dirty link can only be a stale echo;
      # applying it would clobber the newer local edit.
      assert_equal "dirty", link.reload.sync_state.to_s,
        "a stale (older) echo must leave the link dirty for the pending outbound push"
      assert_equal local_description, creative.reload.description,
        "a stale (older) echo must not overwrite the newer local edit"
    end

    test "dirty link + echo whose updatedAt EQUALS the baseline => no-op (own outbound echo)" do
      # The exact finding: local edit A pushed (exporter stores baseline = A's
      # updatedAt), user edits to B (dirty), then Linear echoes A back with the
      # SAME updatedAt. Applying A would silently lose B.
      creative, link = linked_child(linear_issue_id: "iss-echo-equal")
      baseline = Time.current
      link.update!(sync_state: :dirty, remote_updated_at: baseline)
      local_b = creative.reload.description

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-echo-equal",
          "title"     => "Echoed old body A",
          "priority"  => 2,
          "updatedAt" => baseline.iso8601   # equal to baseline (own echo)
        },
        "updatedFrom" => { "title" => "x" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_equal "dirty", link.reload.sync_state.to_s
      assert_equal local_b, creative.reload.description,
        "an equal-timestamp own echo must not overwrite the newer local edit"
    end

    # -- Finding: projectless team issue must not be adopted --------------------

    test "projectless issue create (no projectId, no linked parent) is NOT imported" do
      # A team-scoped webhook for an issue that belongs to no project. With a
      # single linked project the old sole-link fallback would have adopted this
      # backlog issue into the linked subtree.
      assert_equal 1, CollavreLinear::ProjectLink.count,
        "precondition: exactly one linked project (the vulnerable sole-link case)"

      payload = {
        "action" => "create",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-projectless",
          "title"     => "Unrelated backlog issue",
          "priority"  => 0,
          "updatedAt" => Time.current.iso8601
        }
      }

      assert_no_difference [ -> { CollavreLinear::IssueLink.count },
                            -> { Collavre::Creative.count } ] do
        CollavreLinear::InboundApplier.new(payload).apply!
      end
      assert_nil CollavreLinear::IssueLink.find_by(linear_issue_id: "iss-projectless"),
        "a projectless team issue must not be adopted into the linked project's subtree"
    end
  end
end
