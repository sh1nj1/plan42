# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeChangeSetsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @user.update!(email_verified_at: Time.current)
      post session_path, params: { email: @user.email, password: "password" }
      @before = Creatives::History.snapshot(@creative)
      Creatives::History.track(actor: @user, origin: :tool, anchor: @creative, anchor_source: :explicit) do
        @creative.update!(progress: 0.75)
        @change_set = CreativeChangeSet.order(:id).last
      end
    end

    test "revert creates an append-only reverse change set" do
      assert_difference("CreativeChangeSet.count", 1) do
        post creative_apply_change_set_path(@creative, @change_set), params: { mode: "revert" }, as: :json
      end

      assert_response :success
      assert_equal "applied", response.parsed_body["status"]
      assert_equal @before, Creatives::History.snapshot(@creative.reload)
      assert_equal "reverted", @change_set.reload.status
    end

    test "revert returns conflict details after a later edit" do
      Creatives::History.track(actor: @user, origin: :editor, anchor: @creative, anchor_source: :view_root) do
        @creative.update!(progress: 0.9)
      end

      post creative_apply_change_set_path(@creative, @change_set), params: { mode: "revert" }, as: :json

      assert_response :conflict
      assert_equal "conflict", response.parsed_body["status"]
      assert_equal @creative.id, response.parsed_body.dig("conflicts", 0, "creative_id")
    end

    test "revert ignores invalid conflict resolutions" do
      @creative.update!(progress: 0.9)

      post creative_apply_change_set_path(@creative, @change_set),
           params: { mode: "revert", resolutions: { @creative.id => "invalid", bad: "force" } }, as: :json

      assert_response :conflict
      assert_equal "conflict", response.parsed_body["status"]
    end

    test "read-only users cannot force a revert" do
      other = users(:two)
      other.update!(email_verified_at: Time.current)
      CreativeShare.create!(creative: @creative, user: other, shared_by: @user, permission: :read)
      delete session_path
      post session_path, params: { email: other.email, password: "password" }

      post creative_apply_change_set_path(@creative, @change_set),
           params: { mode: "revert", resolutions: { @creative.id => "force" } }, as: :json

      assert_response :unprocessable_entity
      assert_equal "skipped", response.parsed_body["status"]
      assert_equal [ @creative.id ], response.parsed_body["skipped"]
    end

    test "a partial revert stays successful and retryable" do
      foreign = Creative.create!(description: "Foreign after", user: users(:two))
      perform_enqueued_jobs do
        CreativeShare.create!(creative: foreign, user: @user, shared_by: users(:two), permission: :read)
      end
      @change_set.creative_changes.create!(
        creative: foreign,
        operation: "update",
        before: Creatives::History.snapshot(foreign).merge("description" => "Foreign before"),
        after: Creatives::History.snapshot(foreign),
        position: 1
      )

      post creative_apply_change_set_path(@creative, @change_set), params: { mode: "revert" }, as: :json

      assert_response :success
      assert_equal "partial", response.parsed_body["status"]
      assert_equal [ foreign.id ], response.parsed_body["skipped"]
      assert_equal "applied", @change_set.reload.status
    end

    test "restore makes the selected snapshot current without a conflict" do
      @creative.update!(progress: 0.9)

      post creative_apply_change_set_path(@creative, @change_set), params: { mode: "restore" }, as: :json

      assert_response :success
      assert_equal 0.75, @creative.reload.progress
      assert_equal "applied", @change_set.reload.status
    end

    test "revert resolves a change set through a linked Creative scope" do
      linked = nil
      creation = nil
      Creatives::History.track(actor: @user, origin: :tool, anchor: @creative) do
        linked = Creative.create!(user: @user, origin: @creative)
        creation = Current.change_set
      end

      post creative_apply_change_set_path(linked, creation), params: { mode: "revert" }, as: :json

      assert_response :success
      assert linked.reload.archived?
    end

    test "rejects a foreign private linked placement even when its origin is readable" do
      foreign_parent = Creative.create!(description: "Private", user: users(:two))
      linked = Creative.create!(user: users(:two), parent: foreign_parent, origin: @creative)

      post creative_apply_change_set_path(linked, @change_set), params: { mode: "revert" }, as: :json

      assert_response :forbidden
    end
  end
end
