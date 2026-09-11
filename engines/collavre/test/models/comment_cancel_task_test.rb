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

    %w[pending pending_approval].product([ :private, :action, :destroy ]).each do |status, withdrawal|
      test "#{withdrawal} cancels #{status} source task and releases its held slot" do
        task = Task.create!(name: "Paused turn", status: status, agent: @agent, creative: @creative,
          trigger_event_payload: { "comment" => { "id" => @comment.id } })
        tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
        tracker.reset!
        tracker.reserve!(task.id)
        calls = []
        drain = ->(topic_id, creative_id) do
          calls << [ topic_id, creative_id ]
          assert task.reload.cancelled?
          assert_equal 0, tracker.active_jobs
        end

        Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, drain) do
          if withdrawal == :destroy
            @comment.destroy!
          else
            @comment.update!(withdrawal => (withdrawal == :private ? true : '{"tool":"approval"}'))
          end
          assert task.reload.cancelled?
          @comment.send(:cancel_pending_tasks)
        end

        assert_equal [ [ nil, @creative.id ] ], calls
        assert_equal 0, tracker.active_jobs
      end
    end

    %w[pending queued].product([ :private, :action, :destroy ]).each do |status, withdrawal|
      test "#{withdrawal} merged source keeps the valid #{status} anchor and remaining content" do
        anchor = @creative.comments.create!(user: @owner, content: "Anchor", skip_dispatch: true)
        sibling = @creative.comments.create!(user: @owner, content: "Newer sibling", skip_dispatch: true)
        task = Task.create!(name: "Coalesced turn", status: status, agent: @agent, creative: @creative,
          topic_id: anchor.topic_id, trigger_event_payload: {
            "comment" => { "id" => anchor.id }, "workspace_user_id" => @owner.id,
            "merged_comment_ids" => [ @comment.id.to_s, sibling.id ]
          })
        other = Task.create!(name: "Unrelated turn", status: :running, agent: @agent, trigger_event_payload: {})
        Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(*) { flunk "Surviving turn was cancelled" }) do
          if withdrawal == :destroy
            @comment.destroy!
          else
            @comment.update!(withdrawal => (withdrawal == :private ? true : '{"tool":"approval"}'))
          end
        end
        assert_equal status, task.reload.status
        assert_equal anchor.id, task.trigger_event_payload.dig("comment", "id")
        assert_equal "Anchor", task.trigger_event_payload.dig("chat", "content")
        assert_equal [ sibling.id ], task.trigger_event_payload["merged_comment_ids"]
        assert_equal @owner.id, task.trigger_event_payload["workspace_user_id"]
        assert other.reload.running?
      end
    end

    test "withdrawal does not overwrite a task completed after the active scan" do
      task = Task.create!(name: "Paused turn", status: :pending_approval, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => @comment.id } })
      complete = ->(candidate) { Task.where(id: candidate.id).update_all(status: "done"); false }
      @comment.stub(:reanchor_coalesced_task, complete) do
        Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(*) { flunk "No cancellation occurred" }) do
          @comment.update!(private: true)
        end
      end
      assert task.reload.done?
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
