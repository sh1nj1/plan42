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

    test "running_agent_payloads describes a running task" do
      task = create_task(status: "running")

      payloads = agent_statuses_for(@creative)
      assert_equal 1, payloads.size

      status = payloads.first
      assert_equal @agent.id, status[:id]
      assert_equal @agent.display_name, status[:name]
      assert_equal "thinking", status[:status]
      assert_equal task.id, status[:task_id]
    end

    test "running_agent_payloads ignores tasks for other creatives" do
      other_creative = Creative.create!(user: @owner, description: "Other")
      create_task(status: "running", creative: other_creative)

      assert_empty agent_statuses_for(@creative)
    end

    # The job that set pending_approval has already returned, so nothing else will
    # ever announce this task: no heartbeat, no later status. A viewer who reloads
    # while a turn waits on a tool approval has only this replay to learn the task
    # is still holding the slot — and to get its Stop button back.
    test "running_agent_payloads replays a task paused on approval, with its real status" do
      task = create_task(status: "pending_approval")

      payloads = agent_statuses_for(@creative)
      assert_equal 1, payloads.size

      status = payloads.first
      assert_equal task.id, status[:task_id]
      assert_equal "pending_approval", status[:status],
                   "a paused turn replayed as \"thinking\" would claim the agent is working"
    end

    test "running_agent_payloads ignores done tasks" do
      create_task(status: "done")

      assert_empty agent_statuses_for(@creative)
    end

    test "running_agent_payloads ignores cancelled tasks" do
      create_task(status: "cancelled")

      assert_empty agent_statuses_for(@creative)
    end

    private

    def create_task(status:, creative: @creative)
      Task.create!(
        name: "Response to comment_created",
        status: status,
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hello" },
          "creative" => { "id" => creative.id }
        },
        agent: @agent
      )
    end

    def agent_statuses_for(creative)
      CommentsPresenceChannel.running_agent_payloads(creative.id).filter_map { |payload| payload[:agent_status] }
    end
  end

  # The replay has to reach the connection that triggered it. Publishing it to the
  # stream inside #subscribed races the subscription: `stream_from` hands the
  # registration to the pubsub adapter, and the async and Redis adapters attach it
  # asynchronously, so a message published in the same breath can be dropped. That
  # is survivable for presence and badges — later events re-send them — and fatal
  # for this one, because the job holding the task in pending_approval has already
  # returned and nothing will announce it again.
  class CommentsPresenceChannelSubscribeTest < ActionCable::Channel::TestCase
    tests Collavre::CommentsPresenceChannel

    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Subscribe Replay Creative")
      @agent = User.create!(
        email: "presence_subscriber_agent@example.com",
        name: "Presence Subscriber Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )
    end

    test "a task paused on approval is transmitted to the subscriber itself" do
      task = create_task(status: "pending_approval")

      stub_connection current_user: @owner
      subscribe creative_id: @creative.id

      assert subscription.confirmed?
      status = agent_status_transmission
      assert status, "the replay must not depend on the stream the subscription just joined"
      assert_equal task.id, status[:task_id]
      assert_equal "pending_approval", status[:status]
    end

    test "a subscriber with nothing live gets no agent transmission" do
      create_task(status: "done")

      stub_connection current_user: @owner
      subscribe creative_id: @creative.id

      assert subscription.confirmed?
      assert_nil agent_status_transmission
    end

    # Being signed in is not being allowed in. The replay below hands over live
    # task ids and agent names for the creative, which is exactly what
    # TasksController#active_statuses filters by :read — so an unfiltered channel
    # would hand back what the endpoint refuses.
    test "a signed-in user without read permission is rejected and gets nothing" do
      create_task(status: "pending_approval")

      stub_connection current_user: users(:two)
      subscribe creative_id: @creative.id

      assert subscription.rejected?
      assert_nil agent_status_transmission
    end

    test "a shared reader is admitted" do
      task = create_task(status: "pending_approval")
      CreativeShare.create!(creative: @creative, user: users(:two), permission: :read)

      stub_connection current_user: users(:two)
      subscribe creative_id: @creative.id

      assert subscription.confirmed?
      assert_equal task.id, agent_status_transmission[:task_id]
    end

    test "an unknown creative id is rejected instead of raising" do
      stub_connection current_user: @owner
      subscribe creative_id: Creative.maximum(:id).to_i + 1_000

      assert subscription.rejected?
    end

    private

    def create_task(status:)
      Task.create!(
        name: "Response to comment_created",
        status: status,
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )
    end

    def agent_status_transmission
      payload = transmissions.find { |t| t.is_a?(Hash) && (t[:agent_status] || t["agent_status"]) }
      payload && (payload[:agent_status] || payload["agent_status"])
    end
  end
end
