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

    test "running_agent_payloads describes a running task" do
      task = create_task(status: "running", topic: @topic)

      payloads = agent_statuses_for(@creative)
      assert_equal 1, payloads.size

      status = payloads.first
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
        creative: @creative,
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
          creative: @creative,
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

    # Comments always live on the origin, so the channel streams from there — but the
    # replay is scoped to the creative the popup is actually open on, which is what
    # the client keeps as this.creativeId and compares every payload against.
    test "running_agent_payloads replays a task dispatched on the creative in view" do
      linked = Creative.create!(user: users(:two), origin: @creative)
      task = create_task(status: "pending_approval", creative: linked)

      payloads = agent_statuses_for(linked)
      assert_equal 1, payloads.size
      assert_equal task.id, payloads.first[:task_id]
      assert_equal linked.id, payloads.first[:creative_id],
                   "the client filters by the creative the agent is actually working in"
    end

    # A link is a placement, and PermissionFilter#readable_ids deliberately hides
    # foreign placements even when their origin is readable. Replaying every task
    # under the origin would put another user's shell id, task id and agent name on
    # the wire — and the client discards them anyway, since they name a creative it
    # does not have open.
    test "running_agent_payloads does not replay turns from someone else's placement" do
      linked = Creative.create!(user: users(:two), origin: @creative)
      create_task(status: "pending_approval", creative: linked)

      assert_empty agent_statuses_for(@creative)
    end

    # The client appends replayed ids into a per-agent array and treats the last one
    # as the newest turn — Stop cancels that one. Without an ORDER BY, Postgres is
    # free to hand back rows in any order, so Stop could kill an older turn.
    test "the replay query orders tasks by id" do
      assert_match(/ORDER BY\s+"?tasks"?\.?"?id"?/i, CommentsPresenceChannel.replayable_tasks(@creative.id).to_sql,
                   "the client's \"last id is the newest turn\" assumption needs an explicit order")
    end

    # pending_approval turns wait on a human, so the replayable set has no ceiling
    # and spans every tenant. Filtering it in Ruby would make one subscribe load
    # every outstanding approval in the deployment to keep this creative's few.
    test "the replay query narrows to the creative in SQL" do
      assert_match(/creative_id/i, CommentsPresenceChannel.replayable_tasks(@creative.id).to_sql,
                   "opening a chat must not materialize every replayable task in the database")
    end

    test "running_agent_payloads ignores a task whose payload names another creative" do
      other_creative = Creative.create!(user: @owner, description: "Other")
      task = create_task(status: "running")
      task.update!(trigger_event_payload: task.trigger_event_payload.merge(
        "creative" => { "id" => other_creative.id }
      ))

      assert_empty agent_statuses_for(@creative),
                   "the id handed to the client comes from the payload, so it has to agree with the column"
    end

    test "running_agent_payloads replays concurrent turns oldest first" do
      first = create_task(status: "running")
      second = create_task(status: "pending_approval")

      task_ids = agent_statuses_for(@creative).map { |status| status[:task_id] }
      assert_equal [ first.id, second.id ], task_ids,
                   "Stop takes the last id, so the newest turn has to arrive last"
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

    def create_task(status:, creative: @creative, topic: nil)
      payload = {
        "comment" => { "id" => 1, "content" => "Hello" },
        "creative" => { "id" => creative.id }
      }
      payload["topic"] = { "id" => topic.id } if topic

      Task.create!(
        name: "Response to comment_created",
        status: status,
        trigger_event_name: "comment_created",
        trigger_event_payload: payload,
        # Set alongside the payload because every dispatch path writes both from
        # the same context["creative"]["id"], and the replay query filters on the
        # indexed column rather than reading every replayable row in the database.
        creative: creative,
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

    # A shared viewer opens the popup on their own link, not on the origin, so the
    # subscription and the task payload name two different creatives for one turn.
    test "a shared viewer opening their link gets the turn running on it" do
      reader = users(:two)
      linked = Creative.create!(user: reader, origin: @creative)
      CreativeShare.create!(creative: @creative, user: reader, permission: :read)
      task = create_task(status: "pending_approval", creative: linked)

      stub_connection current_user: reader
      subscribe creative_id: linked.id

      assert subscription.confirmed?
      status = agent_status_transmission
      assert status, "the viewer would reload into a paused turn with no Stop button"
      assert_equal task.id, status[:task_id]
    end

    # Readable origin, unreadable placement: the shell sits in another user's private
    # tree, so nothing about the turn running there belongs on this connection.
    test "a turn on someone else's placement is not transmitted to an origin subscriber" do
      foreign_shell = Creative.create!(user: users(:two), origin: @creative)
      create_task(status: "pending_approval", creative: foreign_shell)

      stub_connection current_user: @owner
      subscribe creative_id: @creative.id

      assert subscription.confirmed?
      assert_nil agent_status_transmission
    end

    test "an unknown creative id is rejected instead of raising" do
      stub_connection current_user: @owner
      subscribe creative_id: Creative.maximum(:id).to_i + 1_000

      assert subscription.rejected?
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
        creative: creative,
        agent: @agent
      )
    end

    def agent_status_transmission
      payload = transmissions.find { |t| t.is_a?(Hash) && (t[:agent_status] || t["agent_status"]) }
      payload && (payload[:agent_status] || payload["agent_status"])
    end
  end
end
