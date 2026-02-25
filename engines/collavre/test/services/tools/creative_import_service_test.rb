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

      test "requires approval" do
        assert CreativeImportService.requires_approval?
      end
    end
  end
end
