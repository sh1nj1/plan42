# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CreativeBatchServiceTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Batch Test", email: "batch_test_#{SecureRandom.hex(4)}@example.com", password: "password123")
        Current.user = @user
        @root = Creative.create!(description: "<p>Root</p>", user: @user, progress: 0)
        # Ensure permission cache is populated for the owner
        CreativeSharesCache.find_or_create_by!(creative: @root, user: @user) do |cache|
          cache.permission = :admin
        end
      end

      teardown do
        Current.user = nil
      end

      test "requires_approval? returns true" do
        assert CreativeBatchService.requires_approval?
      end

      test "creates a creative via batch" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "create", "parent_id" => @root.id, "description" => "Batch created task" }
        ])

        assert result[:success]
        assert_equal 1, result[:results].size
        assert result[:results][0][:id].present?
      end

      test "updates a creative via batch" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "update", "id" => @root.id, "progress" => 0.5 }
        ])

        assert result[:success]
        assert_equal 0.5, result[:results][0][:progress]
      end

      test "deletes a creative via batch" do
        child = Creative.create!(description: "<p>To delete</p>", user: @user, parent: @root)

        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "delete", "id" => child.id }
        ])

        assert result[:success]
        assert result[:results][0][:deleted]
        assert_nil Creative.find_by(id: child.id)
      end

      test "mixed operations in a single batch" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "create", "parent_id" => @root.id, "description" => "New task" },
          { "action" => "update", "id" => @root.id, "progress" => 0.75 }
        ])

        assert result[:success]
        assert_equal 2, result[:results].size
      end

      test "unknown action returns error" do
        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "unknown_action" }
        ])

        assert_not result[:success]
        assert_match(/Unknown action/, result[:error])
      end

      test "rolls back all operations on failure" do
        initial_count = Creative.count

        service = CreativeBatchService.new
        result = service.call(operations: [
          { "action" => "create", "parent_id" => @root.id, "description" => "Should be rolled back" },
          { "action" => "delete", "id" => 999_999 }
        ])

        assert_not result[:success]
        assert_equal initial_count, Creative.count
      end
    end
  end
end
