require "test_helper"

module Collavre
  class CommentResendServiceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = Creative.create!(user: @user, description: "Resend")
      @topic = @creative.main_topic
      @earlier = create_message(users(:ai_bot), "Earlier")
      @comment = create_message(@user, "Original")
    end

    test "resend preserves the selected model and thinking level" do
      options = { "model" => "paperclip/claude_local/opus", "reasoning_effort" => "max" }
      @comment.update!(agent_run_options: options)
      assert_equal options, resend.reload.agent_run_options
    end

    test "removes only subsequent visible AI messages in the same topic and preserves human quotes" do
      @earlier.update_column(:created_at, @comment.created_at + 1.day)
      reply = create_message(users(:ai_bot), "Reply", created_at: @comment.created_at - 1.day)
      human = create_message(users(:two), "Human", quoted_comment: reply)
      own_quote = create_message(@user, "My quote", quoted_comment: @comment)
      other_topic = @creative.topics.create!(user: @user, name: "Other")
      elsewhere = create_message(users(:ai_bot), "Elsewhere", topic: other_topic)
      hidden = create_message(users(:ai_bot), "Private", private: true)
      replacement = resend
      assert_not_equal @comment.id, replacement.id
      assert_equal "Original", replacement.content
      assert_equal @topic.id, replacement.topic_id
      assert_not Comment.exists?(@comment.id)
      assert_not Comment.exists?(reply.id)
      [ @earlier, human, own_quote, elsewhere, hidden ].each { |c| assert Comment.exists?(c.id) }
      assert_nil human.reload.quoted_comment_id
      assert_nil own_quote.reload.quoted_comment_id
      assert_operator replacement.created_at, :>=, human.created_at
    end

    test "preserves later permission actions and their delegated task" do
      human = create_message(users(:two), "Later request")
      task = Task.create!(name: "Permission", agent: users(:ai_bot), creative: @creative,
                          topic_id: @topic.id, status: "delegated",
                          trigger_event_payload: { "comment" => { "id" => human.id } },
                          pending_tool_call: { "request_id" => "permission-123" })
      prompt = create_message(users(:ai_bot), "Allow tool?",
                              approver: @user,
                              action: { action: Comment::ClaudeChannelPermission::ACTION_TYPE,
                                        request_id: "permission-123", tool_name: "Bash" }.to_json)
      reply = create_message(users(:ai_bot), "Ordinary reply")
      aborted = []
      AgentSessionAbort.stub :call, ->(**args) { aborted << args[:task].id } do
        resend
      end

      assert Comment.exists?(human.id)
      assert prompt.reload.approval_action?
      assert_nil prompt.task_id
      assert_nil prompt.action_executed_at
      assert_equal "delegated", task.reload.status
      assert_equal "permission-123", task.pending_tool_call["request_id"]
      assert_not_includes aborted, task.id
      assert_not Comment.exists?(reply.id)
    end

    test "removes only pending permission prompts belonging to cancelled tasks and preserves quotes" do
      task, prompt = source_permission
      human = create_message(users(:two), "Quoted permission", quoted_comment: prompt)
      other = create_message(users(:ai_bot), "Other request", action: permission_action("other"))
      decided = create_message(users(:ai_bot), "Decided", action: prompt.action, action_executed_at: Time.current)
      other_topic = @creative.topics.create!(user: @user, name: "Other")
      elsewhere = create_message(users(:ai_bot), "Elsewhere", topic: other_topic, action: prompt.action)
      other_agent = create_message(@user, "Other author", action: prompt.action)
      native = create_message(users(:ai_bot), "Native action", action: { action: "execute_tool", request_id: "source-permission" }.to_json)

      resend

      assert_equal "cancelled", task.reload.status
      assert_not Comment.exists?(prompt.id)
      assert_nil human.reload.quoted_comment_id
      [ other, decided, elsewhere, other_agent, native ].each { |c| assert Comment.exists?(c.id) }
    end

    test "rolls back cancelled permission prompt deletion and its human quote" do
      task, prompt = source_permission
      human = create_message(users(:two), "Quoted permission", quoted_comment: prompt)
      @comment.update_columns(content: "")

      assert_raises(ActiveRecord::RecordInvalid) { resend }

      assert Comment.exists?(prompt.id)
      assert_equal prompt.id, human.reload.quoted_comment_id
      assert_equal "delegated", task.reload.status
      assert_nil prompt.reload.action_executed_at
    end

    test "preserves images mentions and quoted text" do
      quote = create_message(users(:two), "Quoted", created_at: @comment.created_at - 1.second)
      @comment.update!(content: "@AI Bot: look", quoted_comment: quote, quoted_text: "Quoted")
      @comment.images.attach(io: StringIO.new("image"), filename: "image.png", content_type: "image/png")
      blob_id = @comment.images.first.blob_id
      replacement = resend
      assert_equal "@AI Bot: look", replacement.content
      assert_not replacement.private?
      assert_equal quote.id, replacement.quoted_comment_id
      assert_equal "Quoted", replacement.quoted_text
      assert_equal [ blob_id ], replacement.images.pluck(:blob_id)
    end

    test "rolls back deletions quote changes and task cancellation if replacement is invalid" do
      reply = create_message(users(:ai_bot), "Reply", created_at: @comment.created_at - 1.day)
      human = create_message(users(:two), "Human", quoted_comment: reply)
      task = Task.create!(name: "Reply", agent: users(:ai_bot), creative: @creative, topic_id: @topic.id, status: "running")
      reply.update!(task: task)
      @comment.update_columns(content: "")
      assert_raises(ActiveRecord::RecordInvalid) { resend }
      assert Comment.exists?(@comment.id)
      assert Comment.exists?(reply.id)
      assert_equal reply.id, human.reload.quoted_comment_id
      assert_equal "running", task.reload.status
    end

    test "cancels an active task attached to a removed reply and aborts its session" do
      task = Task.create!(name: "Reply", agent: users(:ai_bot), creative: @creative, topic_id: @topic.id, status: "delegated")
      create_message(users(:ai_bot), "Partial", task: task)
      aborted = []
      AgentSessionAbort.stub :call, ->(**args) { aborted << args[:task].id } do
        resend
      end
      assert_equal "cancelled", task.reload.status
      assert_includes aborted, task.id
    end

    test "source deletion cancels a queued task even without a reply" do
      task = Task.create!(name: "Waiting", agent: users(:ai_bot), creative: @creative, topic_id: @topic.id,
                          status: "queued", trigger_event_payload: { "comment" => { "id" => @comment.id } })
      resend
      assert_equal "cancelled", task.reload.status
    end

    %w[queued pending running delegated pending_approval suspended].each do |status|
      test "resending a #{status} source only aborts a session for work that can still own it" do
        earlier_task = Task.create!(name: "Earlier turn", agent: users(:ai_bot), creative: @creative,
                                   topic_id: @topic.id, status: "running",
                                   trigger_event_payload: { "comment" => { "id" => @earlier.id } })
        @earlier.update!(task: earlier_task)
        task = Task.create!(name: "Selected turn", agent: users(:ai_bot), creative: @creative,
                            topic_id: @topic.id, status: status,
                            trigger_event_payload: { "comment" => { "id" => @comment.id } })
        aborted, released, dequeued = [], [], []
        tracker = Object.new
        tracker.define_singleton_method(:release!) { |id| released << id }
        replacement = nil

        AgentSessionAbort.stub :call, ->(**args) { aborted << args[:task].id } do
          Orchestration::ResourceTracker.stub :for, tracker do
            Orchestration::AgentOrchestrator.stub :dequeue_next_for_topic, ->(*args) { dequeued << args } do
              replacement = resend
            end
          end
        end

        assert_equal "cancelled", task.reload.status
        assert_equal "running", earlier_task.reload.status
        assert Comment.exists?(@earlier.id)
        assert replacement.persisted?
        assert_equal %w[queued pending suspended].include?(status) ? [] : [ task.id ], aborted
        held_slot = Task::HELD_SLOT_WITHOUT_WORKER.include?(status)
        assert_equal held_slot ? [ task.id ] : [], released
        assert_equal held_slot ? [ [ @topic.id, @creative.id ] ] : [], dequeued
      end
    end

    test "resending a suspended source does not abort the running successor on the same session" do
      agent = users(:ai_bot)
      task = Task.create!(name: "Suspended turn", agent: agent, creative: @creative,
                          topic_id: @topic.id, status: "suspended",
                          trigger_event_payload: { "comment" => { "id" => @comment.id } })
      later = create_message(@user, "Successor request")
      successor = Task.create!(name: "Running successor", agent: agent, creative: @creative,
                               topic_id: @topic.id, status: "running",
                               trigger_event_payload: { "comment" => { "id" => later.id } })
      aborted = []

      AgentSessionAbort.stub :call, ->(**args) { aborted << args[:task].id } do
        resend
      end

      assert_empty aborted
      assert_equal "cancelled", task.reload.status
      assert_equal "running", successor.reload.status
      assert Comment.exists?(later.id)
      assert_not Comment.exists?(@comment.id)
    end

    test "resend before reply creation prevents a stale worker from inserting an answer" do
      task = Task.create!(name: "Running", agent: users(:ai_bot), creative: @creative,
                          topic_id: @topic.id, status: "running",
                          trigger_event_payload: { "comment" => { "id" => @comment.id } })
      worker = AiAgentService.new(task)
      resend

      assert_no_difference("Comment.count") do
        assert_nil worker.send(:create_reply_comment_if_needed)
      end
      assert_equal "cancelled", task.reload.status
    end

    test "rechecks the source after waiting for the resend topic lock" do
      task = Task.create!(name: "Running", agent: users(:ai_bot), creative: @creative,
                          topic_id: @topic.id, status: "running",
                          trigger_event_payload: { "comment" => { "id" => @comment.id } })
      worker = AiAgentService.new(task)
      mutation = Comments::TopicMutation.method(:call)
      waiting = true
      wrapper = ->(topic_id, creative_id, &block) do
        # Model resend committing while the worker waits to acquire the lock.
        if waiting
          waiting = false
          resend
        end
        mutation.call(topic_id, creative_id, &block)
      end
      Comments::TopicMutation.stub :call, wrapper do
        assert_nil worker.send(:create_reply_comment_if_needed)
      end
      assert_not Comment.exists?(@comment.id)
      assert_nil task.reload.reply_comment
      assert_equal "cancelled", task.status
    end

    test "reply creation holds the resend topic lock until its placeholder is saved" do
      task = Task.create!(name: "Running", agent: users(:ai_bot), creative: @creative,
                          topic_id: @topic.id, status: "running",
                          trigger_event_payload: { "comment" => { "id" => @comment.id } })
      worker = AiAgentService.new(task)
      mutation = Comments::TopicMutation.method(:call)
      locked = false
      wrapper = ->(topic_id, creative_id, &block) do
        assert_equal [ @topic.id, @creative.id ], [ topic_id, creative_id ]
        mutation.call(topic_id, creative_id) do
          locked = true
          block.call
          assert task.reload.reply_comment, "Placeholder must exist before releasing the topic lock"
        end
      end
      reply = Comments::TopicMutation.stub(:call, wrapper) { worker.send(:create_reply_comment_if_needed) }
      assert locked, "Reply creation must serialize with resend"
      assert_equal task.id, reply.task_id
      # Once the worker releases the lock, resend's snapshot includes its reply.
      resend
      assert_not Comment.exists?(reply.id)
      assert_equal "cancelled", task.reload.status
    end

    test "rejects another author and AI authors" do
      assert_raises(CommentResendService::NotAllowed) { resend(user: users(:two)) }
      @comment.update!(user: users(:ai_bot))
      assert_raises(CommentResendService::NotAllowed) { resend(user: users(:ai_bot)) }
    end

    test "rejects an archived creative or topic" do
      @creative.update!(archived_at: Time.current)
      assert_raises(CommentResendService::NotAllowed) { resend }
      @creative.update!(archived_at: nil)
      @topic.update!(archived_at: Time.current)
      assert_raises(CommentResendService::NotAllowed) { resend }
    end

    test "rejects stale scope and a repeated resend" do
      service = CommentResendService.new(comment: @comment, user: @user)
      other = @creative.topics.create!(user: @user, name: "Moved")
      Comment.find(@comment.id).update!(topic: other)
      assert_raises(CommentResendService::NotAllowed) { service.call }
      @comment.reload
      stale = Comment.find(@comment.id)
      resend
      assert_raises(ActiveRecord::RecordNotFound) { CommentResendService.new(comment: stale, user: @user).call }
    end

    test "cancels a source-only delegated task before commit and aborts it" do
      task = Task.create!(name: "Delegated", agent: users(:ai_bot), creative: @creative, topic_id: @topic.id,
                          status: "delegated", trigger_event_payload: { "comment" => { "id" => @comment.id } })
      aborted = []
      AgentSessionAbort.stub :call, ->(**args) { aborted << args } do
        Comment.transaction do
          resend
          assert_equal "cancelled", task.reload.status
          assert_empty aborted
        end
      end
      assert_equal task.id, aborted.first[:task].id
      assert_equal @topic.id, aborted.first[:comment].topic_id
    end

    test "reanchors a coalesced queued task to the surviving human request" do
      human = create_message(users(:two), "Keep working")
      task = Task.create!(name: "Combined", agent: users(:ai_bot), creative: @creative, topic_id: @topic.id,
                          status: "queued", trigger_event_payload: {
                            "comment" => { "id" => @comment.id },
                            "creative" => { "id" => @creative.id }, "topic" => { "id" => @topic.id },
                            "merged_comment_ids" => [ @comment.id, human.id ]
                          })
      resend
      assert_equal "queued", task.reload.status
      assert_equal human.id, task.trigger_event_payload.dig("comment", "id")
      assert Comment.exists?(human.id)
    end

    test "rejects missing feedback permission and approval messages" do
      @creative.stub :has_permission?, false do
        assert_raises(CommentResendService::NotAllowed) { resend }
      end
      @comment.update_columns(action: "{}")
      assert_raises(CommentResendService::NotAllowed) { resend }
    end

    test "rejects History and missing topic scope" do
      @topic.update_column(:system_kind, "history")
      assert_raises(CommentResendService::NotAllowed) { resend }
      Comments::TopicMutation.stub :call, false do
        assert_raises(CommentResendService::NotAllowed) { resend }
      end
    end

    test "rejects inbox System replies without deleting any messages or cross-posting" do
      @creative = Creative.inbox_for(@user)
      @topic = @creative.system_topic(fallback_user: @user)
      destination = Creative.create!(user: @user, description: "Destination")
      original = destination.comments.create!(user: users(:two), content: "Original request")
      create_message(nil, "First alarm", skip_default_user: true, quoted_comment: original)
      @comment = create_message(@user, "My reply")
      InboxReplyService.call(@comment)
      newer = destination.comments.create!(user: users(:two), content: "Different request")
      create_message(nil, "Later alarm", skip_default_user: true, quoted_comment: newer)
      ai_reply = create_message(users(:ai_bot), "Keep reply")

      assert_no_difference("Comment.count") do
        assert_raises(CommentResendService::NotAllowed) { resend }
      end
      assert Comment.exists?(@comment.id)
      assert Comment.exists?(ai_reply.id)
      assert_equal [ original.id ], destination.comments.where(content: "My reply").pluck(:quoted_comment_id)
    end

    test "allows ordinary inbox topics and System topics outside the inbox" do
      @topic.update!(name: Creative::SYSTEM_TOPIC_NAME)
      assert_equal @topic.id, resend.topic_id
      @creative = Creative.inbox_for(@user)
      @topic = @creative.main_topic
      @comment = create_message(@user, "Ordinary inbox chat")
      assert_equal @topic.id, resend.topic_id
    end

    test "outer rollback preserves messages and never aborts a session" do
      task = Task.create!(name: "Delegated", agent: users(:ai_bot), creative: @creative, topic_id: @topic.id,
                          status: "delegated", trigger_event_payload: { "comment" => { "id" => @comment.id } })
      AgentSessionAbort.stub :call, ->(**_args) { flunk "Aborted before commit" } do
        Comment.transaction do
          resend
          raise ActiveRecord::Rollback
        end
      end
      assert Comment.exists?(@comment.id)
      assert_equal "delegated", task.reload.status
    end

    [ false, true ].each do |nested|
      test "aborts the old session before replacement dispatch with nested transaction #{nested}" do
        task = Task.create!(name: "Source", agent: users(:ai_bot), creative: @creative,
                            topic_id: @topic.id, status: "delegated",
                            trigger_event_payload: { "comment" => { "id" => @comment.id } })
        events = []
        tracker = Minitest::Mock.new
        tracker.expect(:release!, nil, [ task.id ])
        AgentSessionAbort.stub :call, ->(**args) { events << [ :abort, args[:task].id ] } do
          Orchestration::ResourceTracker.stub :for, tracker do
            Orchestration::AgentOrchestrator.stub :dequeue_next_for_topic, ->(*) { events << :dequeue } do
              SystemEvents::Dispatcher.stub :dispatch, ->(*) { events << :dispatch } do
                if nested
                  Comment.transaction do
                    resend
                    assert_empty events
                  end
                else
                  resend
                end
              end
            end
          end
        end
        tracker.verify
        assert_equal [ [ :abort, task.id ], :dequeue, :dispatch ], events
        assert_equal "cancelled", task.reload.status
      end

      test "cleans up cancelled tasks when dispatch fails after commit with nested transaction #{nested}" do
        source_task = Task.create!(name: "Source", agent: users(:ai_bot), creative: @creative,
                                   topic_id: @topic.id, status: "delegated",
                                   trigger_event_payload: { "comment" => { "id" => @comment.id } })
        reply_task = Task.create!(name: "Reply", agent: users(:ai_bot), creative: @creative,
                                  topic_id: @topic.id, status: "pending")
        reply = create_message(users(:ai_bot), "Partial", task: reply_task)
        aborted, dequeued = [], []
        tracker = Minitest::Mock.new
        tracker.expect(:release!, nil, [ reply_task.id ])
        tracker.expect(:release!, nil, [ source_task.id ])

        AgentSessionAbort.stub :call, ->(**args) { aborted << args[:task].id } do
          Orchestration::ResourceTracker.stub :for, tracker do
            Orchestration::AgentOrchestrator.stub :dequeue_next_for_topic, ->(*args) { dequeued << args } do
              SystemEvents::Dispatcher.stub :dispatch, ->(*) { raise "Dispatch failed" } do
                error = assert_raises(RuntimeError) do
                  if nested
                    Comment.transaction { resend }
                  else
                    resend
                  end
                end
                assert_equal "Dispatch failed", error.message
              end
            end
          end
        end

        tracker.verify
        assert_equal [ source_task.id ], aborted
        assert_equal [ [ @topic.id, @creative.id ] ] * 2, dequeued
        assert_equal "cancelled", source_task.reload.status
        assert_equal "cancelled", reply_task.reload.status
        assert_not Comment.exists?(@comment.id)
        assert_not Comment.exists?(reply.id)
        assert_equal 1, @creative.comments.where(content: "Original").count
      end
    end

    %w[delegated pending_approval].product([ :abort, :notices, :stranded_notices, :resource, :dequeue ]).each do |status, failure_stage|
      test "continues #{status} task cleanup and dispatch when #{failure_stage} cleanup fails" do
        tasks = 2.times.map do |index|
          task = Task.create!(name: "Reply #{index}", agent: users(:ai_bot), creative: @creative,
                              topic_id: @topic.id, status: status)
          create_message(users(:ai_bot), "Partial #{index}", task: task)
          task
        end
        events, warnings = [], []
        current_task_id = nil
        fail_cleanup = ->(stage) do
          raise "Cleanup unavailable" if failure_stage == stage && current_task_id == tasks.first.id
        end
        tracker = Object.new
        tracker.define_singleton_method(:release!) do |id|
          fail_cleanup.call(:resource)
          events << [ :release, id ]
        end
        AgentSessionAbort.stub :call, ->(**args) { current_task_id = args[:task].id; events << [ :abort, current_task_id ]; fail_cleanup.call(:abort) } do
          Comment.stub :remove_waiter_notices!, ->(**) { fail_cleanup.call(:notices) } do
            Comment.stub :remove_stranded_waiting_notices!, ->(**) { fail_cleanup.call(:stranded_notices) } do
              Orchestration::ResourceTracker.stub :for, tracker do
                Orchestration::AgentOrchestrator.stub :dequeue_next_for_topic, ->(*) { fail_cleanup.call(:dequeue); events << :dequeue } do
                  Rails.logger.stub :warn, ->(message) { warnings << message } do
                    SystemEvents::Dispatcher.stub :dispatch, ->(*) { events << :dispatch } do
                      replacement = resend
                      assert replacement.persisted?
                    end
                  end
                end
              end
            end
          end
        end
        assert_equal [ [ :abort, tasks.last.id ], [ :release, tasks.last.id ], :dequeue, :dispatch ], events.last(4)
        assert_includes events, [ :release, tasks.first.id ] unless failure_stage == :resource
        assert_equal(failure_stage == :dequeue ? 1 : 2, events.count(:dequeue))
        warnings.select! { |message| message.include?("[CommentResendService]") }
        assert_equal 1, warnings.size
        assert_includes warnings.first, "task_id=#{tasks.first.id}"
        assert_includes warnings.first, "RuntimeError"
        assert_not Comment.exists?(@comment.id)
        tasks.each { |task| assert_equal "cancelled", task.reload.status }
      end
    end

    private

    def permission_action(request_id)
      { action: Comment::ClaudeChannelPermission::ACTION_TYPE, request_id: request_id, tool_name: "Bash" }.to_json
    end

    def source_permission
      task = Task.create!(name: "Source permission", agent: users(:ai_bot), creative: @creative,
                          topic_id: @topic.id, status: "delegated",
                          trigger_event_payload: { "comment" => { "id" => @comment.id } },
                          pending_tool_call: { "request_id" => "source-permission" })
      prompt = create_message(users(:ai_bot), "Allow Bash?", approver: @user,
                              action: permission_action("source-permission"))
      [ task, prompt ]
    end

    def create_message(user, content, **attrs)
      @creative.comments.create!({ user: user, content: content, topic: @topic }.merge(attrs))
    end

    def resend(user: @user)
      CommentResendService.new(comment: @comment, user: user).call
    end
  end
end
