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

    test "preserves images privacy mentions and quoted text" do
      quote = create_message(users(:two), "Quoted", created_at: @comment.created_at - 1.second)
      @comment.update!(content: "@AI Bot: look", private: true, quoted_comment: quote, quoted_text: "Quoted")
      @comment.images.attach(io: StringIO.new("image"), filename: "image.png", content_type: "image/png")
      blob_id = @comment.images.first.blob_id
      replacement = resend
      assert_equal "@AI Bot: look", replacement.content
      assert replacement.private?
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
        assert_equal [ reply_task.id, source_task.id ], aborted
        assert_equal [ [ @topic.id, @creative.id ] ] * 2, dequeued
        assert_equal "cancelled", source_task.reload.status
        assert_equal "cancelled", reply_task.reload.status
        assert_not Comment.exists?(@comment.id)
        assert_not Comment.exists?(reply.id)
        assert_equal 1, @creative.comments.where(content: "Original").count
      end
    end

    private

    def create_message(user, content, **attrs)
      @creative.comments.create!({ user: user, content: content, topic: @topic }.merge(attrs))
    end

    def resend(user: @user)
      CommentResendService.new(comment: @comment, user: user).call
    end
  end
end
