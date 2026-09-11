require "test_helper"

module Collavre
  class CommentCancelTaskTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Test Creative")
      @comment = Comment.create!(creative: @creative, user: @owner, content: "Hello AI")
      @agent = User.create!(
        email: "cancel_test_agent@example.com",
        name: "Cancel Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )
    end

    test "ordinary source edits leave active tasks running" do
      task = Task.create!(name: "Active turn", status: :running, agent: @agent,
        trigger_event_payload: { "comment" => { "id" => @comment.id } })
      @comment.update!(content: "Updated request")
      assert task.reload.running?
    end

    test "private waiting notices do not cancel sibling waiters" do
      task = Task.create!(name: "Queued turn", status: :queued, agent: @agent, creative: @creative,
        topic_id: @comment.topic_id, trigger_event_payload: { "comment" => { "id" => @comment.id } })
      notice = @creative.comments.create!(content: "⏳ Waiting", topic_id: @comment.topic_id,
        skip_default_user: true, topic_concurrency_defer: true)
      notice.update!(private: true)
      assert task.reload.queued?
    end

    [ :private, :action ].each do |attribute|
      test "revoking #{attribute} cancels only tasks anchored to the withdrawn source" do
        task = Task.create!(name: "Active turn", status: :running, agent: @agent,
          trigger_event_payload: { "comment" => { "id" => @comment.id } })
        other = Task.create!(name: "Other turn", status: :running, agent: @agent, trigger_event_payload: {})
        @comment.update!(attribute => (attribute == :private ? true : '{"tool":"approval"}'))
        assert task.reload.cancelled?
        assert other.reload.running?
      end
    end

    test "destroying comment cancels running tasks triggered by that comment" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => @comment.id, "content" => "Hello AI" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      @comment.destroy!

      assert_equal "cancelled", task.reload.status
    end

    test "destroying comment cancels pending tasks triggered by that comment" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "pending",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => @comment.id, "content" => "Hello AI" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      @comment.destroy!

      assert_equal "cancelled", task.reload.status
    end

    test "destroying comment cancels delegated tasks and releases agent slot" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "delegated",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => @comment.id, "content" => "Hello AI" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent,
        creative_id: @creative.id
      )

      tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
      tracker.reset!
      tracker.reserve!(task.id)
      assert_equal 1, tracker.active_jobs

      dequeue_called_with = nil
      stub = ->(t, c = nil) { dequeue_called_with = [ t, c ] }

      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, stub) do
        @comment.destroy!
      end

      assert_equal "cancelled", task.reload.status
      assert_equal 0, Collavre::Orchestration::ResourceTracker.for(@agent).active_jobs,
        "Expected the delegated task's slot to be released when its trigger comment is deleted"
      assert_equal [ nil, @creative.id ], dequeue_called_with
    end

    test "destroying comment cancels queued tasks triggered by that comment" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "queued",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => @comment.id, "content" => "Hello AI" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      @comment.destroy!

      assert_equal "cancelled", task.reload.status
    end

    test "destroying comment does not affect done tasks" do
      task = Task.create!(
        name: "Response to comment_created",
        status: "done",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => @comment.id, "content" => "Hello AI" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      @comment.destroy!

      assert_equal "done", task.reload.status
    end

    test "destroying comment does not affect tasks for other comments" do
      other_comment = Comment.create!(creative: @creative, user: @owner, content: "Other")
      task = Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => other_comment.id, "content" => "Other" },
          "creative" => { "id" => @creative.id }
        },
        agent: @agent
      )

      @comment.destroy!

      assert_equal "running", task.reload.status
    end
  end
end
