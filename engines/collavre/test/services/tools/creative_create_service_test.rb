require "test_helper"

module Collavre
  module Tools
    class CreativeCreateServiceTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @user = User.create!(name: "Test User", email: "test_create@example.com", password: "password123")
        Current.user = @user
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @parent_creative = Creative.create!(
          description: "<p>Parent Creative</p>",
          user: @user
        )
      end

      teardown do
        Current.user = nil
        ActiveJob::Base.queue_adapter = @original_adapter
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

      test "stores a direct agent create as a draft under review policy" do
        task, agent = review_agent_turn(@parent_creative)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeCreateService.new.call(parent_id: @parent_creative.id, description: "Proposed")
        end

        assert result[:pending_review], result.inspect
        assert_not @parent_creative.children.where("description LIKE ?", "%Proposed%").exists?
        assert CreativeChangeSet.find(result[:change_set_id]).creative_changes.where("creative_id < 0").exists?
      end

      test "stores sibling resequencing as a draft when the sibling requires review" do
        sibling = Creative.create!(
          description: "Protected sibling", user: @user, parent: @parent_creative,
          data: { "ai_write_policy" => "review" }
        )
        task, agent = agent_turn(@parent_creative)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeCreateService.new.call(
            parent_id: @parent_creative.id, description: "Before sibling", before_id: sibling.id
          )
        end

        assert result[:pending_review], result.inspect
        assert_not @parent_creative.children.where("description LIKE ?", "%Before sibling%").exists?
        assert_equal 0, sibling.reload.sequence
      end

      test "stores parent progress propagation as a draft when an ancestor requires review" do
        review_root = Creative.create!(
          description: "Review root", user: @user,
          data: { "ai_write_policy" => "review" }
        )
        @parent_creative.update!(
          parent: review_root,
          data: @parent_creative.data.merge("ai_write_policy" => "auto")
        )
        task, agent = agent_turn(review_root)

        result = Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          CreativeCreateService.new.call(parent_id: @parent_creative.id, description: "Proposed child")
        end

        assert result[:pending_review], result.inspect
        assert_not @parent_creative.children.where("description LIKE ?", "%Proposed child%").exists?
      end

      test "stores the description as Markdown-canonical" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "New task item"
        )

        assert result[:success]
        creative = Creative.find(result[:id])
        assert_equal "markdown", creative.data["content_type"]
        assert_equal "New task item", creative.data["markdown_source"]
        # Tool/MCP writes default to the advanced (source) editing surface.
        assert_equal "source", creative.data["editor"]
      end

      test "renders Markdown formatting in the description" do
        service = CreativeCreateService.new

        result = service.call(
          parent_id: @parent_creative.id,
          description: "# Heading\n\n- one\n- two\n\n**bold** text"
        )

        assert result[:success], "Expected success but got: #{result[:error]}"
        creative = Creative.find(result[:id])
        assert_includes creative.description, "Heading</h1>"
        assert_includes creative.description, "<li>one</li>"
        assert_includes creative.description, "<li>two</li>"
        assert_includes creative.description, "<strong>bold</strong>"
        assert_equal "# Heading\n\n- one\n- two\n\n**bold** text", creative.data["markdown_source"]
      end

      test "passes raw HTML through (backward compatible)" do
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

      test "records sibling resequencing when inserting before a sibling" do
        Collavre::CreativeChangeSet.destroy_all
        Current.reset
        first = Creative.create!(description: "First", user: @user, parent: @parent_creative, sequence: 0)
        second = Creative.create!(description: "Second", user: @user, parent: @parent_creative, sequence: 1)
        Current.user = @user

        result = CreativeCreateService.new.call(
          parent_id: @parent_creative.id,
          description: "Inserted",
          before_id: second.id
        )

        assert result[:success]
        created = Creative.find(result.fetch(:id))
        changes = CreativeChangeSet.sole.creative_changes.index_by(&:creative_id)
        assert_equal [ created.id, second.id ].sort, changes.keys.sort
        assert_equal "create", changes.fetch(created.id).operation
        assert_equal 1, changes.fetch(created.id).after.fetch("sequence")
        assert_equal [ 2, 1 ], [ created, second ].map { |creative| creative.reload.revision }
        assert_equal 0, first.reload.revision
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

      test "enqueues broadcast job after create" do
        service = CreativeCreateService.new

        assert_enqueued_with(job: CreativeBroadcastJob) do
          result = service.call(
            parent_id: @parent_creative.id,
            description: "Broadcast test"
          )
          assert result[:success]
        end
      end

      test "raises error when no current user" do
        Current.user = nil
        service = CreativeCreateService.new

        assert_raises(RuntimeError) do
          service.call(description: "No user task")
        end
      end

      private

      def review_agent_turn(creative)
        creative.update!(data: creative.data.merge("ai_write_policy" => "review"))
        agent_turn(creative)
      end

      def agent_turn(creative)
        agent = users(:ai_bot)
        perform_enqueued_jobs(only: PermissionCacheJob) do
          CreativeShare.create!(creative: creative, user: agent, shared_by: @user, permission: :write)
        end
        topic = Topic.create!(creative: creative, user: @user, name: "Review create")
        task = Task.create!(agent: agent, creative: creative, topic_id: topic.id, name: "Review", status: "running")
        [ task, agent ]
      end
    end
  end
end
