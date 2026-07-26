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
        # Pinning requires the agent to be able to answer here (see
        # Topic.primary_agent_assignable?), so the agent under test is shared.
        CreativeShare.create!(creative: @creative, user: @ai_agent, shared_by: @user, permission: :feedback)
        @topic = Topic.create!(creative: @creative, user: @user, name: "Test Topic")
      end

      test "creates topic with quoted name" do
        comment = create_comment('/topic "My New Topic"')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/My New Topic/, result)
        assert Topic.exists?(creative: @creative, name: "My New Topic")
      end

      test "broadcasts to TopicsChannel when topic is created" do
        comment = create_comment('/topic "Broadcast Topic"')

        broadcast_called = false
        TopicsChannel.stub(:broadcast_to, ->(_creative, data) {
          broadcast_called = true
          assert_equal "created", data[:action]
          assert_equal "Broadcast Topic", data[:topic][:name]
          assert_equal @user.id, data[:user_id]
        }) do
          TopicCommand.new(comment: comment, user: @user).call
        end

        assert broadcast_called, "Expected TopicsChannel.broadcast_to to be called"
        assert Topic.exists?(creative: @creative, name: "Broadcast Topic")
      end

      test "broadcasts with primary agent info when agent is mentioned" do
        comment = create_comment('/topic "Agent Broadcast" @TestAgent: ')

        broadcast_called = false
        TopicsChannel.stub(:broadcast_to, ->(_creative, data) {
          broadcast_called = true
          assert_equal "created", data[:action]
          assert data[:topic][:primary_agent].present?, "Expected primary_agent in broadcast"
          assert_equal @ai_agent.id, data[:topic][:primary_agent][:id]
        }) do
          TopicCommand.new(comment: comment, user: @user).call
        end

        assert broadcast_called
      end

      test "does not broadcast when topic already exists" do
        Topic.create!(creative: @creative, user: @user, name: "Existing Broadcast Topic")
        comment = create_comment('/topic "Existing Broadcast Topic"')

        broadcast_called = false
        TopicsChannel.stub(:broadcast_to, ->(_creative, _data) {
          broadcast_called = true
        }) do
          TopicCommand.new(comment: comment, user: @user).call
        end

        refute broadcast_called, "Expected TopicsChannel.broadcast_to NOT to be called for existing topic"
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
        assert_equal @ai_agent.id, topic.primary_agent_id
      end

      test "creates topic without agent when mention not found" do
        comment = create_comment('/topic "No Agent Topic" @nonexistent_agent: ')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/No Agent Topic/, result)
        assert Topic.exists?(creative: @creative, name: "No Agent Topic")

        # No primary agent should be set
        topic = Topic.find_by(creative: @creative, name: "No Agent Topic")
        assert_nil topic.primary_agent_id
      end

      # User.mentionable_for resolves every searchable agent, shared or not, so
      # /topic could otherwise pin an agent that cannot answer — which mutes the
      # topic outright, since the pin also excludes every other agent.
      test "refuses to pin an agent that has no feedback access on the creative" do
        outsider = User.create!(
          email: "outsider@test.local", password: "password123", name: "OutsiderAgent",
          llm_vendor: "openai", llm_model: "gpt-4", searchable: true
        )
        comment = create_comment('/topic "Outsider Topic" @OutsiderAgent: ')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/OutsiderAgent/, result)
        assert_not Topic.exists?(creative: @creative, name: "Outsider Topic")
        assert_nil Topic.find_by(primary_agent_id: outsider.id)
      end

      test "leaves an existing topic's agent untouched when the mention has no access" do
        @topic.set_primary_agent!(@ai_agent)
        outsider = User.create!(
          email: "outsider2@test.local", password: "password123", name: "OutsiderAgent2",
          llm_vendor: "openai", llm_model: "gpt-4", searchable: true
        )
        comment = create_comment('/topic "Test Topic" @OutsiderAgent2: ')

        TopicCommand.new(comment: comment, user: @user).call

        assert_equal @ai_agent.id, @topic.reload.primary_agent_id
      end

      # The pin decides who may speak in the topic, so changing it is a routing
      # change: TopicsController#set_primary_agent requires :write. Comments are
      # authorized at :feedback, so without this gate commenting access would be
      # enough to redirect an existing topic from chat.
      test "refuses to release an assignment for a commenter without write access" do
        @topic.set_primary_agent!(@ai_agent)
        commenter = users(:two)
        CreativeShare.create!(creative: @creative, user: commenter, shared_by: @user, permission: :feedback)
        comment = create_comment('/topic "Test Topic"', user: commenter)

        result = TopicCommand.new(comment: comment, user: commenter).call

        assert_match(/write permission/i, result)
        assert_equal @ai_agent.id, @topic.reload.primary_agent_id
      end

      test "refuses to reassign an existing topic for a commenter without write access" do
        @topic.set_primary_agent!(@ai_agent)
        other_agent = User.create!(
          email: "otheragent@test.local", password: "password123", name: "OtherAgent",
          llm_vendor: "openai", llm_model: "gpt-4", searchable: true
        )
        CreativeShare.create!(creative: @creative, user: other_agent, shared_by: @user, permission: :feedback)
        commenter = users(:two)
        CreativeShare.create!(creative: @creative, user: commenter, shared_by: @user, permission: :feedback)
        comment = create_comment('/topic "Test Topic" @OtherAgent: ', user: commenter)

        result = TopicCommand.new(comment: comment, user: commenter).call

        assert_match(/write permission/i, result)
        assert_equal @ai_agent.id, @topic.reload.primary_agent_id
      end

      test "lets a write collaborator release an assignment" do
        @topic.set_primary_agent!(@ai_agent)
        collaborator = users(:two)
        CreativeShare.create!(creative: @creative, user: collaborator, shared_by: @user, permission: :write)
        comment = create_comment('/topic "Test Topic"', user: collaborator)

        TopicCommand.new(comment: comment, user: collaborator).call

        assert_nil @topic.reload.primary_agent_id
      end

      # The gate must cover only the assignment write — naming an unassigned
      # topic still just reports that it exists, which commenters may do.
      test "still reports an unassigned existing topic to a commenter without write access" do
        commenter = users(:two)
        CreativeShare.create!(creative: @creative, user: commenter, shared_by: @user, permission: :feedback)
        comment = create_comment('/topic "Test Topic"', user: commenter)

        result = TopicCommand.new(comment: comment, user: commenter).call

        assert_match(/already exists/i, result)
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

        # Primary agent set on existing topic
        existing.reload
        assert_equal @ai_agent.id, existing.primary_agent_id
        assert_match(/TestAgent/, result)
      end

      test "replaces primary agent on existing topic" do
        existing = Topic.create!(creative: @creative, user: @user, name: "Agent Swap Topic")

        # Set initial primary agent
        other_agent = User.create!(
          email: "other@test.local", password: "password123", name: "OtherAgent",
          llm_vendor: "openai", llm_model: "gpt-4", searchable: true
        )
        existing.set_primary_agent!(other_agent)

        # Update to new agent
        comment = create_comment('/topic "Agent Swap Topic" @TestAgent: ')
        TopicCommand.new(comment: comment, user: @user).call

        existing.reload
        assert_equal @ai_agent.id, existing.primary_agent_id
      end

      test "releases primary agent when existing assigned topic is named without a mention" do
        existing = Topic.create!(creative: @creative, user: @user, name: "Release Topic")
        existing.set_primary_agent!(@ai_agent)

        comment = create_comment('/topic "Release Topic"')
        result = TopicCommand.new(comment: comment, user: @user).call

        existing.reload
        assert_nil existing.primary_agent_id
        assert_match(/Release Topic/, result)
      end

      # A session topic's primary agent is its identity, not a routing pin, so
      # /topic must neither release nor reassign it.
      test "leaves a session topic's primary agent untouched" do
        existing = Topic.create!(creative: @creative, user: @user, name: "Session Topic")
        existing.set_primary_agent!(@ai_agent)
        existing.update!(session_id: "sess-xyz789")

        comment = create_comment('/topic "Session Topic"')
        result = TopicCommand.new(comment: comment, user: @user).call

        assert_equal @ai_agent.id, existing.reload.primary_agent_id
        assert_match(/Session Topic/, result)
      end

      test "reports already exists when topic exists without agent mention" do
        Topic.create!(creative: @creative, user: @user, name: "Duplicate Topic")
        comment = create_comment('/topic "Duplicate Topic"')

        result = TopicCommand.new(comment: comment, user: @user).call

        assert_match(/Duplicate Topic/, result)
        assert_match(/already exists/i, result)
      end

      private

      def create_comment(content, user: @user)
        Collavre::Comment.create!(
          creative: @creative,
          topic: @topic,
          user: user,
          content: content
        )
      end
    end
  end
end
