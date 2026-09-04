# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeImportServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @parent = Collavre::Creative.create!(description: "Import Target", progress: 0.0, user: @user)
        Collavre::Current.user = @user
        @service = CreativeImportService.new
      end

      test "imports heading hierarchy via MarkdownImporter" do
        markdown = <<~MD
          # Project Plan
          ## Phase 1
          ## Phase 2
        MD

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        assert_equal 3, result[:created_count]
        assert_equal @parent.id, result[:parent_id]

        @parent.reload
        project = @parent.children.first
        assert_includes project.description, "Project Plan"
        assert_equal 2, project.children.count

        change_set = CreativeChangeSet.sole
        assert_equal "import", change_set.origin
        assert_equal "import_target", change_set.anchor_source
        assert_equal @parent.id, change_set.anchor_creative_id
        assert_equal 3, change_set.creative_changes.count
      end

      test "imports bullet lists as children" do
        markdown = <<~MD
          # Tasks
          - Item one
          - Item two
        MD

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        assert_equal 3, result[:created_count]

        tasks = @parent.children.first
        assert_equal 2, tasks.children.count
      end

      test "keeps import and later writes in one agent turn change set" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @parent, user: agent, shared_by: @user, permission: :write)
        topic = Topic.create!(creative: @parent, user: @user, name: "Agent import")
        task = Task.create!(agent: agent, creative: @parent, topic_id: topic.id, name: "Import", status: "running")

        Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          result = @service.call(markdown: "# Imported", parent_id: @parent.id)
          assert result[:success]
          @parent.update!(description: "Updated in the same turn")
        end

        change_set = CreativeChangeSet.sole
        assert_equal "tool", change_set.origin
        assert_equal task.id, change_set.task_id
        assert_equal topic.id, change_set.topic_id
        assert_equal @parent.id, change_set.anchor_creative_id
        assert_equal 2, change_set.creative_changes.count
      end

      test "returns error for invalid parent_id" do
        result = @service.call(markdown: "# Test", parent_id: 999999)
        assert_equal "Parent Creative not found", result[:error]
      end

      test "returns error without write permission" do
        other_user = users(:two)
        Collavre::Current.user = other_user

        result = @service.call(markdown: "# Test", parent_id: @parent.id)
        assert_equal "No write permission on parent Creative", result[:error]
      end

      test "returns tree with created ids" do
        result = @service.call(markdown: "# Hello", parent_id: @parent.id)

        assert result[:success]
        assert_equal 1, result[:tree].size
        assert result[:tree].first[:id].present?
        assert_equal @parent.id, result[:tree].first[:parent_id]
      end

      test "does not use the opaque pre-execution approval gate" do
        assert_not CreativeImportService.requires_approval?
      end

      test "stores an inherited review-policy import as a draft without creating rows" do
        @parent.update!(data: @parent.data.merge("ai_write_policy" => "review"))
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @parent, user: agent, shared_by: @user, permission: :write)
        topic = Topic.create!(creative: @parent, user: @user, name: "Review import")
        task = Task.create!(agent: agent, creative: @parent, topic_id: topic.id, name: "Import", status: "running")
        initial_count = Creative.count

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          @service.call(markdown: "# Project\n## Child", parent_id: @parent.id)
        end

        assert result[:pending_review]
        assert_equal initial_count, Creative.count
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal "draft", draft.status
        assert_equal 2, draft.creative_changes.where("creative_id < 0").count
        root, child = draft.creative_changes.order(:position).to_a
        assert_equal root.creative_id, child.after["parent_id"]
      end

      test "stores import progress propagation as a draft when an ancestor requires review" do
        review_root = Creative.create!(
          description: "Review root", user: @user,
          data: { "ai_write_policy" => "review" }
        )
        @parent.update!(parent: review_root, data: @parent.data.merge("ai_write_policy" => "auto"))
        agent = users(:ai_bot)
        CreativeShare.create!(creative: review_root, user: agent, shared_by: @user, permission: :write)
        topic = Topic.create!(creative: review_root, user: @user, name: "Review import propagation")
        task = Task.create!(agent: agent, creative: review_root, topic_id: topic.id, name: "Import", status: "running")
        initial_count = Creative.count

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          @service.call(markdown: "# Proposed", parent_id: @parent.id)
        end

        assert result[:pending_review], result.inspect
        assert_equal initial_count, Creative.count
      end
    end
  end
end
