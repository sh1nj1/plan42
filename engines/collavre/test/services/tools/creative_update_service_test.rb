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

      test "stores a direct agent update as a draft under review policy" do
        task, agent = review_agent_turn(@creative)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeUpdateService.new.call(id: @creative.id, description: "Proposed")
        end

        assert result[:pending_review]
        assert_equal "<p>Original</p>", @creative.reload.description
        assert_equal "draft", CreativeChangeSet.find(result[:change_set_id]).status
      end

      test "stores a move into a review-policy parent as a draft" do
        destination = Creative.create!(description: "Destination", user: @user)
        task, agent = review_agent_turn(destination)
        CreativeShare.create!(creative: @creative, user: agent, shared_by: @user, permission: :write)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeUpdateService.new.call(id: @creative.id, parent_id: destination.id)
        end

        assert result[:pending_review]
        assert_nil @creative.reload.parent_id
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal destination.id, draft.creative_changes.find_by!(creative_id: @creative.id).after["parent_id"]
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

      test "stores the updated description as Markdown-canonical" do
        service = CreativeUpdateService.new

        result = service.call(
          id: @creative.id,
          description: "# Updated\n\n- a\n- b"
        )

        assert result[:success], "Expected success but got: #{result[:error]}"
        @creative.reload
        assert_equal "markdown", @creative.data["content_type"]
        assert_equal "# Updated\n\n- a\n- b", @creative.data["markdown_source"]
        assert_includes @creative.description, "Updated</h1>"
        assert_includes @creative.description, "<li>a</li>"
      end

      test "tool description update forces the source editor over a prior rich preference" do
        @creative.update!(content_type_input: "markdown", markdown_source: "rich body", markdown_editor: "rich")
        assert_equal "rich", @creative.reload.data["editor"]

        service = CreativeUpdateService.new
        result = service.call(
          id: @creative.id,
          description: "| a | b |\n| - | - |\n| 1 | 2 |"
        )

        assert result[:success], "Expected success but got: #{result[:error]}"
        @creative.reload
        assert_equal "markdown", @creative.data["content_type"]
        assert_equal "source", @creative.data["editor"]
      end

      test "updates progress without a description change keeps Markdown source" do
        @creative.update!(content_type_input: "markdown", markdown_source: "# Keep me")
        assert_equal "markdown", @creative.reload.data["content_type"]

        service = CreativeUpdateService.new
        result = service.call(id: @creative.id, progress: 1.0)

        assert result[:success], "Expected success but got: #{result[:error]}"
        @creative.reload
        assert_in_delta 1.0, @creative.progress, 0.01
        assert_equal "markdown", @creative.data["content_type"]
        assert_equal "# Keep me", @creative.data["markdown_source"]
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

      test "rejects a destination parent without write permission" do
        other_user = User.create!(name: "Other Parent", email: "other_parent@example.com", password: "password123")
        new_parent = Creative.create!(description: "<p>Private parent</p>", user: other_user)

        result = CreativeUpdateService.new.call(id: @creative.id, parent_id: new_parent.id)

        assert_match(/permission/i, result[:error])
        assert_nil @creative.reload.parent_id
      end

      test "returns validation failures from the update" do
        service = CreativeUpdateService.new

        result = Creative.stub(:find_by, @creative) do
          @creative.stub(:save, false) do
            service.call(id: @creative.id, description: "Rejected by model")
          end
        end

        assert_match(/failed to update/i, result[:error])
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

      test "does not change parent_id when parent_id is nil" do
        parent = Creative.create!(description: "<p>Parent</p>", user: @user)
        @creative.update!(parent: parent)

        service = CreativeUpdateService.new
        result = service.call(id: @creative.id, description: "<p>Updated</p>", parent_id: nil)

        assert result[:success]
        @creative.reload
        assert_equal parent.id, @creative.parent_id
      end

      test "does not change parent_id when parent_id is 0" do
        parent = Creative.create!(description: "<p>Parent</p>", user: @user)
        @creative.update!(parent: parent)

        service = CreativeUpdateService.new
        result = service.call(id: @creative.id, description: "<p>Updated</p>", parent_id: 0)

        assert result[:success]
        @creative.reload
        assert_equal parent.id, @creative.parent_id
      end

      test "returns error when parent_id is set to self" do
        service = CreativeUpdateService.new
        result = service.call(id: @creative.id, parent_id: @creative.id)

        assert result[:error].present?
        assert_match(/own parent/i, result[:error])
      end

      test "raises error when no current user" do
        Current.user = nil
        service = CreativeUpdateService.new

        assert_raises(RuntimeError) do
          service.call(id: @creative.id, description: "No user")
        end
      end

      private

      def review_agent_turn(creative)
        creative.update!(data: creative.data.merge("ai_write_policy" => "review"))
        agent = users(:ai_bot)
        CreativeShare.create!(creative: creative, user: agent, shared_by: @user, permission: :write)
        topic = Topic.create!(creative: creative, user: @user, name: "Review update")
        task = Task.create!(agent: agent, creative: creative, topic_id: topic.id, name: "Review", status: "running")
        [ task, agent ]
      end
    end
  end
end
