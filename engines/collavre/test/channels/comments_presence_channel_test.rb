require "test_helper"

module Collavre
  class CommentsPresenceChannelTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Test Creative")
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
          "creative" => { "id" => @creative.id }
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

    # The job that set pending_approval has already returned, so nothing else will
    # ever announce this task: no heartbeat, no later status. A viewer who reloads
    # while a turn waits on a tool approval has only this replay to learn the task
    # is still holding the slot — and to get its Stop button back.
    test "broadcast_running_agents replays a task paused on approval, with its real status" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "pending_approval",
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
      assert_equal 1, agent_broadcasts.size

      status = agent_broadcasts.first[:payload][:agent_status]
      assert_equal task.id, status[:task_id]
      assert_equal "pending_approval", status[:status],
                   "a paused turn replayed as \"thinking\" would claim the agent is working"
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
