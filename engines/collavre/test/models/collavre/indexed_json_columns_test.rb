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
  end
end
