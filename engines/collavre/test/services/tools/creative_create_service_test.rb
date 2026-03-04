require "test_helper"

module Collavre
  module Tools
    class CreativeCreateServiceTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Test User", email: "test_create@example.com", password: "password123")
        Current.user = @user
        @parent_creative = Creative.create!(
          description: "<p>Parent Creative</p>",
          user: @user
        )
      end

      teardown do
        Current.user = nil
      end

      test "creates a creative with plain text description" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "New task item"
        )

        assert result[:success], "Expected success but got: #{result[:error]}"
        assert result[:id].present?

        creative = Creative.find(result[:id])
        assert_equal "<p>New task item</p>", creative.description
        assert_equal @parent_creative.id, creative.parent_id
        assert_equal 0, creative.progress
      end

      test "creates a creative with HTML description" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "<p>HTML <strong>formatted</strong> content</p>"
        )

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_equal "<p>HTML <strong>formatted</strong> content</p>", creative.description
      end

      test "creates a creative with progress" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "Task at 50%",
          progress: 0.5
        )

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_in_delta 0.5, creative.progress, 0.01
      end

      test "creates a root creative when no parent_id" do
        service = CreativeCreateService.new

        result = service.call(description: "Root level task")

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_nil creative.parent_id
        assert_equal @user, creative.user
      end

      test "returns error when parent not found" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: 999999,
          description: "Orphan task"
        )

        assert result[:error].present?
        assert_match(/not found/i, result[:error])
      end

      test "returns error when no write permission on parent" do
        other_user = User.create!(name: "Other User", email: "other_create@example.com", password: "password123")
        other_creative = Creative.create!(
          description: "<p>Other user's creative</p>",
          user: other_user
        )

        service = CreativeCreateService.new

        result = service.call(
          parent_id: other_creative.id,
          description: "Unauthorized task"
        )

        assert result[:error].present?
        assert_match(/permission/i, result[:error])
      end

      test "strips leading and trailing whitespace from plain text description" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "  New task with spaces  "
        )

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_equal "<p>New task with spaces</p>", creative.description
      end

      test "strips leading and trailing whitespace from HTML description" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "  <p>HTML with spaces</p>  "
        )

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_equal "<p>HTML with spaces</p>", creative.description
      end

      test "strips newlines from description" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "\nNew task with newlines\n"
        )

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_equal "<p>New task with newlines</p>", creative.description
      end

      test "raises error when no current user" do
        Current.user = nil
        service = CreativeCreateService.new

        assert_raises(RuntimeError) do
          service.call(description: "No user task")
        end
      end
    end
  end
end
