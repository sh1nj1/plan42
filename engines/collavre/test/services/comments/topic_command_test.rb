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
