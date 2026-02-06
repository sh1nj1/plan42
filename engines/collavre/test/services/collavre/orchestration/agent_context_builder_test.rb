require "test_helper"

module Collavre
  module Orchestration
    class AgentContextBuilderTest < ActiveSupport::TestCase
      setup do
        @human_user = Collavre::User.create!(
          name: "John",
          email: "john-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )

        # Create AI agent
        @ai_agent = Collavre::User.create!(
          name: "dev-agent",
          email: "dev-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are a developer agent specialized in Ruby on Rails."
        )

        # Create another AI agent for collaboration
        @qa_agent = Collavre::User.create!(
          name: "qa-agent",
          email: "qa-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are a QA engineer focused on testing and quality assurance."
        )

        # Create PM agent
        @pm_agent = Collavre::User.create!(
          name: "pm-agent",
          email: "pm-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are a project manager coordinating development tasks."
        )

        # Create creative
        @creative = Collavre::Creative.create!(
          description: "Test project",
          user: @human_user
        )
      end

      test "builds agent identity" do
        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        assert_equal @ai_agent.id, result["agent"]["id"]
        assert_equal "dev-agent", result["agent"]["name"]
        assert_equal "developer", result["agent"]["type"]
      end

      test "extracts agent type from system prompt" do
        builder = AgentContextBuilder.new(agent: @qa_agent, creative: @creative)
        result = builder.build

        assert_equal "qa", result["agent"]["type"]
      end

      test "builds empty collaborators when no other agents have access" do
        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        assert_empty result["collaborators"]
      end

      test "builds collaborators from creative shares" do
        # Share creative with QA agent (write permission)
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @qa_agent,
          permission: :write
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        assert_equal 1, result["collaborators"].length
        collaborator = result["collaborators"].first
        assert_equal @qa_agent.id, collaborator["id"]
        assert_equal "qa-agent", collaborator["name"]
        assert_equal "collaborator", collaborator["role"]
        assert_equal "write", collaborator["permission"]
      end

      test "maps admin permission to escalation role" do
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @pm_agent,
          permission: :admin
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        collaborator = result["collaborators"].find { |c| c["id"] == @pm_agent.id }
        assert_equal "escalation", collaborator["role"]
      end

      test "maps feedback permission to reviewer role" do
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @qa_agent,
          permission: :feedback
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        collaborator = result["collaborators"].first
        assert_equal "reviewer", collaborator["role"]
      end

      test "maps read permission to reference role" do
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @qa_agent,
          permission: :read
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        collaborator = result["collaborators"].first
        assert_equal "reference", collaborator["role"]
      end

      test "excludes self from collaborators" do
        # Share creative with self
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @ai_agent,
          permission: :write
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        assert_empty result["collaborators"]
      end

      test "excludes no_access permission" do
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @qa_agent,
          permission: :no_access
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        assert_empty result["collaborators"]
      end

      test "excludes human users from collaborators" do
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @human_user,
          permission: :admin
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        result = builder.build

        # Human user should not be in collaborators
        human_collaborator = result["collaborators"].find { |c| c["id"] == @human_user.id }
        assert_nil human_collaborator
      end

      test "inherits permissions from parent creatives" do
        # Create parent creative with QA agent access
        parent = Collavre::Creative.create!(
          description: "Parent project",
          user: @human_user
        )

        Collavre::CreativeShare.create!(
          creative: parent,
          user: @qa_agent,
          permission: :write
        )

        # Create child creative
        child = Collavre::Creative.create!(
          description: "Child task",
          user: @human_user,
          parent: parent
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: child)
        result = builder.build

        # QA agent should be available from parent permission
        assert_equal 1, result["collaborators"].length
        assert_equal @qa_agent.id, result["collaborators"].first["id"]
      end

      test "keeps highest permission level when multiple exist" do
        # Create parent with read permission
        parent = Collavre::Creative.create!(
          description: "Parent project",
          user: @human_user
        )

        Collavre::CreativeShare.create!(
          creative: parent,
          user: @qa_agent,
          permission: :read
        )

        # Create child with write permission
        child = Collavre::Creative.create!(
          description: "Child task",
          user: @human_user,
          parent: parent
        )

        Collavre::CreativeShare.create!(
          creative: child,
          user: @qa_agent,
          permission: :write
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: child)
        result = builder.build

        collaborator = result["collaborators"].first
        assert_equal "write", collaborator["permission"]
        assert_equal "collaborator", collaborator["role"]
      end

      test "generates collaboration prompt" do
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @pm_agent,
          permission: :admin
        )

        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @qa_agent,
          permission: :feedback
        )

        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        prompt = builder.to_collaboration_prompt

        assert_includes prompt, "## 협업 가능한 Agent"
        assert_includes prompt, "### 에스컬레이션 대상"
        assert_includes prompt, "@pm-agent"
        assert_includes prompt, "### 리뷰어"
        assert_includes prompt, "@qa-agent"
        assert_includes prompt, "## 협업 규칙"
      end

      test "returns empty string when no collaborators" do
        builder = AgentContextBuilder.new(agent: @ai_agent, creative: @creative)
        prompt = builder.to_collaboration_prompt

        assert_equal "", prompt
      end

      test "handles nil creative gracefully" do
        builder = AgentContextBuilder.new(agent: @ai_agent, creative: nil)
        result = builder.build

        assert_equal @ai_agent.id, result["agent"]["id"]
        assert_empty result["collaborators"]
      end
    end
  end
end
