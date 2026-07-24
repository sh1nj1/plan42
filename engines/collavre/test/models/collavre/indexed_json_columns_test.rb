# frozen_string_literal: true

require "test_helper"

module Collavre
  # Exercises Collavre::IndexedJsonColumns through Collavre::Channel, the model
  # that promotes `config` keys into real indexed columns.
  class IndexedJsonColumnsTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user
      @creative = Creative.create!(description: "Test Creative", user: @user)
      @topic = Topic.create!(name: "Channel Topic", creative: @creative, user: @user)
    end

    test "declares the JSON source and column map on the model" do
      assert_equal :config, Channel.indexed_json_source
      assert_equal(
        { "repo_full_name" => "repo_full_name",
          "pr_number" => "pr_number",
          "worktree_id" => "worktree_id" },
        Channel.indexed_json_column_map
      )
    end

    test "syncs JSON keys into promoted columns on create" do
      channel = Channel.create!(
        topic: @topic,
        type: "Collavre::Channel",
        config: { "repo_full_name" => "acme/app", "pr_number" => 42, "worktree_id" => "wt-1" }
      )

      assert_equal "acme/app", channel.repo_full_name
      assert_equal 42, channel.pr_number
      assert_equal "wt-1", channel.worktree_id
      # Persisted, not just in-memory.
      reloaded = Channel.find(channel.id)
      assert_equal "acme/app", reloaded.repo_full_name
      assert_equal 42, reloaded.pr_number
    end

    test "re-syncs promoted columns when the JSON field changes on save" do
      channel = Channel.create!(
        topic: @topic,
        type: "Collavre::Channel",
        config: { "repo_full_name" => "acme/app", "pr_number" => 1 }
      )
      assert_equal "acme/app", channel.repo_full_name

      channel.update!(config: { "repo_full_name" => "acme/other", "pr_number" => 7 })

      assert_equal "acme/other", channel.reload.repo_full_name
      assert_equal 7, channel.pr_number
    end

    test "clears promoted column when the JSON key is removed" do
      channel = Channel.create!(
        topic: @topic,
        type: "Collavre::Channel",
        config: { "worktree_id" => "wt-9" }
      )
      assert_equal "wt-9", channel.worktree_id

      channel.update!(config: {})

      assert_nil channel.reload.worktree_id
    end

    # Regression: a full migration replay reaches older record-saving migrations
    # (e.g. 20251230113607_refactor_labels calls Creative.create!) before the
    # add-column migration that promotes the indexed key. The before_save must
    # not abort the save by writing a column the table does not have yet.
    test "skips promoted columns absent from the table instead of raising" do
      original_map = Channel.indexed_json_column_map
      Channel.indexed_json_column_map = original_map.merge("kind_not_yet_added" => "kind").freeze
      begin
        channel = nil
        assert_nothing_raised do
          channel = Channel.create!(
            topic: @topic,
            type: "Collavre::Channel",
            config: { "repo_full_name" => "acme/app", "kind" => "profile" }
          )
        end
        # Existing promoted columns are still synced; only the missing one is skipped.
        assert_equal "acme/app", channel.repo_full_name
      ensure
        Channel.indexed_json_column_map = original_map
      end
    end
  end
end
