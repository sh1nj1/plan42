require "test_helper"

module Collavre
  module Tools
    class CreativeUpdateServiceTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Test User", email: "test_update@example.com", password: "password123")
        Current.user = @user
        @creative = Creative.create!(
          description: "<p>Original</p>",
          user: @user,
          progress: 0
        )
      end

      teardown do
        Current.user = nil
      end

      test "updates description with HTML" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          description: "<p>Updated <em>content</em></p>"
        )

        assert result[:success], "Expected success but got: #{result[:error]}"
        @creative.reload
        assert_equal "<p>Updated <em>content</em></p>", @creative.description
      end

      test "updates description with plain text" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          description: "Plain text update"
        )

        assert result[:success]
        @creative.reload
        assert_equal "<p>Plain text update</p>", @creative.description
      end

      test "updates progress to 1.0 on leaf creative" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          progress: 1.0
        )

        assert result[:success]
        @creative.reload
        assert_in_delta 1.0, @creative.progress, 0.01
      end

      test "rejects partial progress update" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          progress: 0.75
        )

        assert result[:error].present?
        assert_match(/only progress of 1.0/i, result[:error])
        @creative.reload
        assert_in_delta 0.0, @creative.progress, 0.01
      end

      test "rejects progress update on parent creative" do
        child = Creative.create!(
          description: "<p>Child</p>",
          user: @user,
          parent: @creative
        )

        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          progress: 1.0
        )

        assert result[:error].present?
        assert_match(/leaf/i, result[:error])
      end

      test "updates parent_id" do
        new_parent = Creative.create!(
          description: "<p>New parent</p>",
          user: @user
        )
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          parent_id: new_parent.id
        )

        assert result[:success]
        @creative.reload
        assert_equal new_parent.id, @creative.parent_id
      end

      test "returns error when creative not found" do
        service = CreativeUpdateService.new

        result = service.call(
          id: 999999,
          description: "Update nonexistent"
        )

        assert result[:error].present?
        assert_match(/not found/i, result[:error])
      end

      test "returns error when no write permission" do
        other_user = User.create!(name: "Other User", email: "other_update@example.com", password: "password123")
        other_creative = Creative.create!(
          description: "<p>Other's creative</p>",
          user: other_user
        )

        service = CreativeUpdateService.new

        result = service.call(
          id: other_creative.id,
          description: "Unauthorized update"
        )

        assert result[:error].present?
        assert_match(/permission/i, result[:error])
      end

      test "prevents circular parent reference" do
        child = Creative.create!(
          description: "<p>Child</p>",
          user: @user,
          parent: @creative
        )

        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          parent_id: child.id
        )

        assert result[:error].present?
        assert_match(/descendant/i, result[:error])
      end

      test "strips leading and trailing whitespace from plain text description" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          description: "  Updated with spaces  "
        )

        assert result[:success]
        @creative.reload
        assert_equal "<p>Updated with spaces</p>", @creative.description
      end

      test "strips leading and trailing whitespace from HTML description" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          description: "  <p>Updated HTML with spaces</p>  "
        )

        assert result[:success]
        @creative.reload
        assert_equal "<p>Updated HTML with spaces</p>", @creative.description
      end

      test "strips newlines from description" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          description: "\nUpdated with newlines\n"
        )

        assert result[:success]
        @creative.reload
        assert_equal "<p>Updated with newlines</p>", @creative.description
      end

      test "raises error when no current user" do
        Current.user = nil
        service = CreativeUpdateService.new

        assert_raises(RuntimeError) do
          service.call(id: @creative.id, description: "No user")
        end
      end
    end
  end
end
