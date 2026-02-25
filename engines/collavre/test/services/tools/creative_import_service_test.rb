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

      test "imports simple heading hierarchy" do
        markdown = <<~MD
          # Project Plan
          ## Phase 1
          Setup infrastructure
          ## Phase 2
          Build features
        MD

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        assert_equal 3, result[:created_count]
        assert_equal @parent.id, result[:parent_id]

        # Verify tree structure
        @parent.reload
        children = @parent.children.order(:id)
        assert_equal 1, children.size # "Project Plan"

        project = children.first
        assert_includes project.description, "Project Plan"

        phases = project.children.order(:id)
        assert_equal 2, phases.size
        assert_includes phases[0].description, "Phase 1"
        assert_includes phases[0].description, "Setup infrastructure"
        assert_includes phases[1].description, "Phase 2"
        assert_includes phases[1].description, "Build features"
      end

      test "imports deeply nested headings" do
        markdown = <<~MD
          # Level 1
          ## Level 2
          ### Level 3
          #### Level 4
        MD

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        assert_equal 4, result[:created_count]

        level1 = @parent.children.first
        level2 = level1.children.first
        level3 = level2.children.first
        level4 = level3.children.first

        assert_includes level1.description, "Level 1"
        assert_includes level2.description, "Level 2"
        assert_includes level3.description, "Level 3"
        assert_includes level4.description, "Level 4"
      end

      test "handles sibling headings at same level" do
        markdown = <<~MD
          # Task A
          # Task B
          # Task C
        MD

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        assert_equal 3, result[:created_count]
        assert_equal 3, @parent.children.count
      end

      test "returns error for empty markdown" do
        result = @service.call(markdown: "just some text without headings", parent_id: @parent.id)

        assert_equal "No headings found in markdown", result[:error]
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

      test "handles body with list items" do
        markdown = <<~MD
          # Tasks
          - Item one
          - Item two
          - Item three
        MD

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        task = @parent.children.first
        assert_includes task.description, "<ul>"
        assert_includes task.description, "Item one"
      end

      test "heading-only nodes get simple description" do
        markdown = "# Simple Title\n"

        result = @service.call(markdown: markdown, parent_id: @parent.id)

        assert result[:success]
        creative = @parent.children.first
        assert_equal "<p>Simple Title</p>", creative.description
      end

      test "requires approval" do
        assert CreativeImportService.requires_approval?
      end
    end
  end
end
