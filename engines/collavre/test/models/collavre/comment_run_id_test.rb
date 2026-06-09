# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentRunIdTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = Creative.create!(description: "test", progress: 0.0, user: @user)
      Collavre::Current.user = @user
    end

    test "claim_openclaw_run_id backfills the run_id" do
      comment = @creative.comments.create!(content: "reply", user: @user)

      comment.claim_openclaw_run_id("run-1")

      assert_equal "run-1", comment.reload.openclaw_run_id
    end

    test "claim_openclaw_run_id is a no-op for a blank run_id" do
      comment = @creative.comments.create!(content: "reply", user: @user)

      comment.claim_openclaw_run_id(nil)

      assert_nil comment.reload.openclaw_run_id
    end

    test "claim_openclaw_run_id does not overwrite an existing run_id" do
      comment = @creative.comments.create!(content: "reply", user: @user, openclaw_run_id: "run-keep")

      comment.claim_openclaw_run_id("run-other")

      assert_equal "run-keep", comment.reload.openclaw_run_id
    end

    test "claim_openclaw_run_id reclaims the run from a proactive duplicate and removes it" do
      duplicate = @creative.comments.create!(
        content: "proactive duplicate", user: @user, openclaw_run_id: "run-race"
      )
      canonical = @creative.comments.create!(content: "canonical reply", user: @user)

      canonical.claim_openclaw_run_id("run-race")

      assert_equal "run-race", canonical.reload.openclaw_run_id, "canonical owns the run_id"
      assert_not Comment.exists?(duplicate.id), "duplicate is removed"
      assert_equal canonical.id, Comment.where(openclaw_run_id: "run-race").sole.id
    end
  end
end
