require "test_helper"

module Collavre
  module Comments
    class TopicCommandTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        # Create AI agent with name without spaces for easier @mention matching
        @ai_agent = User.create!(
          email: "testagent@test.local",
          password: "password123",
          name: "TestAgent",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          searchable: true
        )
        @topic = Topic.create!(creative: @creative, user: @user, name: "Test Topic")
      end

      test "creates topic with quoted name" do
        comment = create_comment('/topic "My New Topic"')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/My New Topic/, result)
        assert Topic.exists?(creative: @creative, name: "My New Topic")
      end

      test "creates topic with smart quotes" do
        comment = create_comment('/topic "Smart Quotes Topic"')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/Smart Quotes Topic/, result)
        assert Topic.exists?(creative: @creative, name: "Smart Quotes Topic")
      end

      test "creates topic with primary agent via mention" do
        comment = create_comment('/topic "Agent Topic" @TestAgent: ')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/Agent Topic/, result)
        assert_match(/TestAgent/, result)

        topic = Topic.find_by(creative: @creative, name: "Agent Topic")
        assert topic.present?

        policy = OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: topic.id)
        assert policy.present?
        assert_equal "arbitration", policy.policy_type
        assert_equal "primary_first", policy.config["strategy"]
        assert_equal @ai_agent.id, policy.config["primary_agent_id"]
      end

      test "creates topic without agent when mention not found" do
        comment = create_comment('/topic "No Agent Topic" @nonexistent_agent: ')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/No Agent Topic/, result)
        assert Topic.exists?(creative: @creative, name: "No Agent Topic")

        # No policy should be created
        topic = Topic.find_by(creative: @creative, name: "No Agent Topic")
        assert_nil OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: topic.id)
      end

      test "returns error when topic name is missing" do
        comment = create_comment("/topic")

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/specify.*name/i, result)
      end

      test "returns nil for non-topic commands" do
        comment = create_comment("Hello world")

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_nil result
      end

      test "is case insensitive" do
        comment = create_comment('/TOPIC "Uppercase Command"')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/Uppercase Command/, result)
        assert Topic.exists?(creative: @creative, name: "Uppercase Command")
      end

      test "updates primary agent on existing topic" do
        existing = Topic.create!(creative: @creative, user: @user, name: "Existing Topic")
        comment = create_comment('/topic "Existing Topic" @TestAgent: ')

        topic_count_before = Topic.where(creative: @creative, name: "Existing Topic").count
        result = TopicCommand.new(comment: comment, user: @user).call

        # No new topic created
        assert_equal topic_count_before, Topic.where(creative: @creative, name: "Existing Topic").count

        # Policy created for existing topic
        policy = OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: existing.id)
        assert policy.present?
        assert_equal @ai_agent.id, policy.config["primary_agent_id"]
        assert_match(/TestAgent/, result)
      end

      test "replaces primary agent on existing topic" do
        existing = Topic.create!(creative: @creative, user: @user, name: "Agent Swap Topic")

        # Set initial primary agent
        other_agent = User.create!(
          email: "other@test.local", password: "password123", name: "OtherAgent",
          llm_vendor: "openai", llm_model: "gpt-4", searchable: true
        )
        OrchestratorPolicy.create!(
          policy_type: "arbitration", scope_type: "Topic", scope_id: existing.id,
          config: { "strategy" => "primary_first", "primary_agent_id" => other_agent.id },
          priority: 10, enabled: true
        )

        # Update to new agent
        comment = create_comment('/topic "Agent Swap Topic" @TestAgent: ')
        TopicCommand.new(comment: comment, user: @user).call

        policy = OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: existing.id)
        assert_equal @ai_agent.id, policy.config["primary_agent_id"]
        # Should be only one policy, not two
        assert_equal 1, OrchestratorPolicy.where(scope_type: "Topic", scope_id: existing.id, policy_type: "arbitration").count
      end

      test "reports already exists when topic exists without agent mention" do
        Topic.create!(creative: @creative, user: @user, name: "Duplicate Topic")
        comment = create_comment('/topic "Duplicate Topic"')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/Duplicate Topic/, result)
        assert_match(/already exists/i, result)
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
