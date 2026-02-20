require "test_helper"

module Collavre
  module Comments
    class WorkCommandTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @ai_agent = User.create!(
          email: "testagent@test.local",
          password: "password123",
          name: "TestAgent",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          searchable: true
        )
        @topic = Topic.create!(creative: @creative, user: @user, name: "Test Topic")

        # Create child creatives
        @child1 = Creative.create!(
          description: "Child Creative 1",
          user: @user,
          parent: @creative,
          sequence: 1
        )
        @child2 = Creative.create!(
          description: "Child Creative 2",
          user: @user,
          parent: @creative,
          sequence: 2
        )
        @grandchild = Creative.create!(
          description: "Grandchild Creative",
          user: @user,
          parent: @child1,
          sequence: 1
        )
      end

      test "creates workflow for child creatives with DFS order" do
        comment = create_comment('/work @TestAgent: Analyze and improve each creative')

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_match(/Workflow started/, result)
        assert_match(/TestAgent/, result)
        assert_match(/3 tasks queued/, result)

        # Check parent task was created
        parent_task = Task.find_by(creative: @creative, workflow_context: "Analyze and improve each creative")
        assert parent_task.present?
        assert_equal "running", parent_task.status
        assert parent_task.workflow_parent?
        assert_equal [ @child1.id, @grandchild.id, @child2.id ], parent_task.workflow_state["pending_creative_ids"]
      end

      test "skips creatives that already have tasks" do
        # Create existing task for child1
        Task.create!(
          name: "Existing task",
          status: "running",
          agent: @ai_agent,
          creative: @child1
        )

        comment = create_comment('/work @TestAgent: Process remaining creatives')

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_match(/2 tasks queued/, result)
        assert_match(/1 skipped/, result)

        parent_task = Task.find_by(creative: @creative, workflow_context: "Process remaining creatives")
        assert_equal [ @grandchild.id, @child2.id ], parent_task.workflow_state["pending_creative_ids"]
      end

      test "returns error when no AI agent is mentioned" do
        comment = create_comment('/work Analyze and improve each creative')

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_match(/mention an AI agent/, result)
      end

      test "returns error when creative has no children" do
        childless_creative = Creative.create!(description: "Childless", user: @user)
        comment = Comment.create!(
          creative: childless_creative,
          topic: @topic,
          user: @user,
          content: '/work @TestAgent: Do something'
        )

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_match(/no child creatives/, result)
      end

      test "returns error when all children already have tasks" do
        [ @child1, @child2, @grandchild ].each do |creative|
          Task.create!(
            name: "Existing task",
            status: "running",
            agent: @ai_agent,
            creative: creative
          )
        end

        comment = create_comment('/work @TestAgent: Process creatives')

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_match(/already have active tasks/, result)
      end

      test "extracts workflow context correctly" do
        comment = create_comment('/work @TestAgent: Complex workflow context with multiple words')

        WorkCommand.new(comment: comment, user: @user).call

        parent_task = Task.find_by(creative: @creative)
        assert_equal "Complex workflow context with multiple words", parent_task.workflow_context
      end

      test "returns nil for non-work commands" do
        comment = create_comment("Hello world")

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_nil result
      end

      test "is case insensitive" do
        comment = create_comment('/WORK @TestAgent: Uppercase command')

        result = WorkCommand.new(comment: comment, user: @user).call

        assert_match(/Workflow started/, result)
      end

      private

      def create_comment(content)
        Collavre::Comment.create!(
          creative: @creative,
          topic: @topic,
          user: @user,
          content: content
        )
      end
    end
  end
end
