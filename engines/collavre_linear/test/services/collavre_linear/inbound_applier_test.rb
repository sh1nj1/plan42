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

    test "update writes sequence via the model (priority 1 => sequence 1)" do
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

      assert_equal 1, creative.reload.sequence,
        "priority 1 should map to sequence 1 via FieldMapper + model save"
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

    test "update to an unlinked parentId does NOT reparent to a bogus node" do
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
          "parentId"  => "iss-not-linked-here",
          "updatedAt" => Time.current.iso8601
        },
        "updatedFrom" => { "parentId" => "iss-p-a" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      child.reload
      child_link.reload
      assert_equal parent_a.id, child.parent_id,
        "creative must not move when the new Linear parent is not a linked issue"
      assert_equal "iss-p-a", child_link.parent_issue_id
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

    # -- Step 4: conflict ------------------------------------------------------

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

    test "dirty link but remote NOT newer => no conflict, applies normally" do
      creative, link = linked_child(linear_issue_id: "iss-noconf")
      link.update!(sync_state: :dirty, remote_updated_at: Time.current)

      payload = {
        "action" => "update",
        "type"   => "Issue",
        "data"   => {
          "id"        => "iss-noconf",
          "title"     => "Older remote",
          "priority"  => 2,
          "updatedAt" => 1.hour.ago.iso8601   # older than remote_updated_at (now)
        },
        "updatedFrom" => { "title" => "x" }
      }

      CollavreLinear::InboundApplier.new(payload).apply!

      assert_not_equal "conflict", link.reload.sync_state.to_s
      assert_includes creative.reload.description, "Older remote"
    end
  end
end
