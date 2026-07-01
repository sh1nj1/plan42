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

    test "dirty link + newer remote => conflict, system comment posted, fields unchanged" do
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
