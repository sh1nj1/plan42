require "test_helper"

module Collavre
  class CommentsPresenceChannelTest < ActionCable::Channel::TestCase
    tests Collavre::CommentsPresenceChannel

    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Test Creative")
      @topic = @creative.main_topic
      @agent = User.create!(
        email: "presence_agent@example.com",
        name: "Presence Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )
    end

    test "broadcast_running_agents sends agent status for running tasks" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hello" },
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        },
        agent: @agent
      )

      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, payload) { broadcasts << { channel: channel, payload: payload } } do
        CommentsPresenceChannel.broadcast_running_agents(@creative.id)
      end

      agent_broadcasts = broadcasts.select { |b| b[:payload].key?(:agent_status) }
      assert_equal 1, agent_broadcasts.size

      status = agent_broadcasts.first[:payload][:agent_status]
      assert_equal @agent.id, status[:id]
      assert_equal @agent.display_name, status[:name]
      assert_equal "thinking", status[:status]
      assert_equal task.id, status[:task_id]
      assert_equal @topic.id, status[:topic_id]
    end

    test "broadcast_running_agents derives the workflow topic from its trigger comment" do
      trigger_comment = @creative.comments.create!(
        content: "Workflow request",
        user: @owner,
        topic_id: nil,
        skip_dispatch: true
      )
      task = Task.create!(
        name: "Workflow response",
        status: "running",
        trigger_event_name: "workflow",
        trigger_event_payload: {
          "comment" => { "id" => trigger_comment.id },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, payload) { broadcasts << { channel: channel, payload: payload } } do
        CommentsPresenceChannel.broadcast_running_agents(@creative.id)
      end

      status = broadcasts.find { |broadcast| broadcast[:payload].key?(:agent_status) }[:payload][:agent_status]
      assert_equal task.id, status[:task_id]
      assert_equal @topic.id, status[:topic_id]
    end

    test "broadcast_running_agents filters snapshots by topic" do
      other_topic = @creative.topics.create!(name: "Other", user: @owner)
      [ @topic, other_topic ].each do |topic|
        Task.create!(
          name: "Response in #{topic.name}",
          status: "running",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id }
          },
          agent: @agent
        )
      end

      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, payload) { broadcasts << { channel: channel, payload: payload } } do
        CommentsPresenceChannel.broadcast_running_agents(@creative.id, topic_id: other_topic.id)
      end

      statuses = broadcasts.filter_map { |broadcast| broadcast[:payload][:agent_status] }
      assert_equal [ other_topic.id ], statuses.pluck(:topic_id)
    end

    test "typing broadcasts the validated topic id" do
      stub_connection current_user: @owner
      subscribe creative_id: @creative.id
      assert subscription.confirmed?

      assert_broadcast_on(
        "comments_presence:#{@creative.id}",
        { typing: { id: @owner.id, name: @owner.display_name, topic_id: @topic.id } }
      ) do
        perform :typing, topic_id: @topic.id
      end
    end

    test "stopped typing broadcasts the validated topic id" do
      stub_connection current_user: @owner
      subscribe creative_id: @creative.id
      assert subscription.confirmed?

      assert_broadcast_on(
        "comments_presence:#{@creative.id}",
        { stop_typing: { id: @owner.id, topic_id: @topic.id } }
      ) do
        perform :stopped_typing, topic_id: @topic.id
      end
    end

    test "typing ignores a topic from another creative" do
      other_creative = Creative.create!(user: @owner, description: "Other")
      stub_connection current_user: @owner
      subscribe creative_id: @creative.id

      assert_no_broadcasts("comments_presence:#{@creative.id}") do
        perform :typing, topic_id: other_creative.main_topic.id
      end
    end

    test "stopped typing ignores a missing topic" do
      stub_connection current_user: @owner
      subscribe creative_id: @creative.id

      assert_no_broadcasts("comments_presence:#{@creative.id}") do
        perform :stopped_typing
      end
    end

    test "running agents action requests a snapshot for a validated topic" do
      requested = []
      stub_connection current_user: @owner
      subscribe creative_id: @creative.id

      CommentsPresenceChannel.stub :broadcast_running_agents, ->(creative_id, topic_id:) {
        requested << [ creative_id, topic_id ]
      } do
        perform :running_agents, topic_id: @topic.id
      end

      assert_equal [ [ @creative.id, @topic.id ] ], requested
    end

    test "broadcast_running_agents ignores tasks for other creatives" do
      other_creative = Creative.create!(user: @owner, description: "Other")
      Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hello" },
          "creative" => { "id" => other_creative.id }
        },
        agent: @agent
      )

      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, payload) { broadcasts << { channel: channel, payload: payload } } do
        CommentsPresenceChannel.broadcast_running_agents(@creative.id)
      end

      agent_broadcasts = broadcasts.select { |b| b[:payload].key?(:agent_status) }
      assert_equal 0, agent_broadcasts.size
    end

    test "broadcast_running_agents ignores done tasks" do
      Task.create!(
        name: "Response to comment_created",
        status: "done",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, payload) { broadcasts << { channel: channel, payload: payload } } do
        CommentsPresenceChannel.broadcast_running_agents(@creative.id)
      end

      agent_broadcasts = broadcasts.select { |b| b[:payload].key?(:agent_status) }
      assert_equal 0, agent_broadcasts.size
    end

    test "broadcast_running_agents ignores cancelled tasks" do
      Task.create!(
        name: "Response to comment_created",
        status: "cancelled",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, payload) { broadcasts << { channel: channel, payload: payload } } do
        CommentsPresenceChannel.broadcast_running_agents(@creative.id)
      end

      agent_broadcasts = broadcasts.select { |b| b[:payload].key?(:agent_status) }
      assert_equal 0, agent_broadcasts.size
    end
  end
end
