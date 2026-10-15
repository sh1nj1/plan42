# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TaskTrackingTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @other = users(:two)
        @creative = Creative.create!(description: "Tracking", user: @owner)
        @topic = @creative.topics.create!(name: "Work", user: @owner)
        @comment = @topic.comments.create!(creative: @creative, user: @owner, content: "Implement", skip_dispatch: true)
        Current.user = @owner
      end

      teardown { Current.reset }

      test "tracks trigger on create and when payload changes" do
        task = make_task
        assert_equal @comment.id, task.trigger_comment_id
        task.update!(trigger_event_payload: {})
        assert_nil task.reload.trigger_comment_id
        assert_nil make_task(payload: nil).trigger_comment_id
      end

      test "lists all active statuses and terminal tasks separately" do
        Task.statuses.each_key { |status| make_task(status: status) }
        active = TopicTasksService.new.call(topic_id: @topic.id)
        assert_equal Task::ACTIVE_STATUSES.sort, active[:tasks].pluck(:status).sort
        finished = TopicTasksService.new.call(topic_id: @topic.id, status: "finished")
        assert_equal %w[cancelled done escalated failed], finished[:tasks].pluck(:status).sort
        assert_equal Task.statuses.size, TopicTasksService.new.call(topic_id: @topic.id, status: "all")[:tasks].size
      end

      test "paginates newest tasks deterministically and scopes to topic and creative" do
        first = make_task
        newest = make_task
        make_task(topic_id: nil)
        result = TopicTasksService.new.call(topic_id: @topic.id, limit: 1)
        assert_equal [ newest.id ], result[:tasks].pluck(:task_id)
        assert result[:has_more]
        assert_equal [ newest.id, first.id ], TopicTasksService.new.call(topic_id: @topic.id)[:tasks].pluck(:task_id)
      end

      test "describes visible reply and suspension without exposing hidden replies" do
        task = make_task(status: "suspended", suspend_reason: "quota")
        reply = @topic.comments.create!(creative: @creative, user: @owner, content: "<p>Ready</p>", task_id: task.id, skip_dispatch: true)
        row = TaskStatusService.new.call(comment_id: @comment.id)[:tasks].sole
        assert_equal reply.id, row[:reply_comment_id]
        assert_equal "Ready", row[:reply_summary]
        assert_equal "quota", row[:suspend_reason]
        assert_equal({ id: @owner.id, name: @owner.display_name }, row[:agent])
        reply.update!(private: true, user: @other)
        assert_nil TaskStatusService.new.call(task_ids: task.id)[:tasks].sole[:reply_summary]
      end

      test "never includes approval prompts or replies from another creative" do
        task = make_task
        reply = @topic.comments.create!(creative: @creative, user: @owner, content: "secret", task_id: task.id,
          action: "tool_call", skip_dispatch: true)
        assert_nil TaskStatusService.new.call(task_ids: task.id)[:tasks].sole[:reply_comment_id]
        reply.update!(action: nil, creative: Creative.create!(description: "Elsewhere", user: @other))
        assert_nil TaskStatusService.new.call(task_ids: task.id)[:tasks].sole[:reply_comment_id]
      end

      test "empty dispatch remains not started" do
        assert_equal "not_started", TaskStatusService.new.call(comment_id: @comment.id)[:status]
      end

      test "aggregates every status and gives attention priority" do
        expected = { "done" => "done", "cancelled" => "cancelled", "failed" => "needs_attention",
          "escalated" => "needs_attention", "pending_approval" => "needs_attention" }
        Task.statuses.each_key do |status|
          task = make_task(status: status)
          assert_equal expected.fetch(status, "in_progress"), TaskStatusService.new.call(task_ids: task.id)[:status], status
        end
        assert_equal "needs_attention", TaskStatusService.new.call(comment_id: @comment.id)[:status]
      end

      test "follows descendant causation across topics and excludes correlation siblings" do
        event = SystemEvents::Envelope.root("comment_created")
        root = make_task(status: "done", payload: payload(event))
        child_event = SystemEvents::Envelope.child("comment_created", parent: event)
        child = make_task(payload: payload(child_event).except("comment"), topic_id: nil)
        grandchild = make_task(status: "queued", payload: payload(SystemEvents::Envelope.child("comment_created", parent: child_event)).except("comment"))
        sibling_event = SystemEvents::Envelope.root("comment_created").with(correlation_id: event.correlation_id)
        make_task(status: "failed", payload: payload(sibling_event).except("comment"))
        result = TaskStatusService.new.call(task_ids: root.id.to_s)
        assert_equal "in_progress", result[:status]
        assert_equal [ root.id, child.id, grandchild.id ].sort, result[:tasks].pluck(:task_id).sort
      end

      test "cycles terminate and duplicate requested ids are deduplicated" do
        event = SystemEvents::Envelope.root("comment_created")
        child = SystemEvents::Envelope.child("comment_created", parent: event)
        root = make_task(status: "done", payload: payload(event.with(causation_id: child.id)))
        other = make_task(status: "done", payload: payload(child))
        result = TaskStatusService.new.call(task_ids: [ root.id, root.id, other.id ])
        assert_equal 2, result[:tasks].size
        assert_equal "done", result[:status]
      end

      test "rejects invalid arguments and unknown ids" do
        [ {}, { comment_id: @comment.id, task_ids: "1" }, { task_ids: [] }, { task_ids: "oops" },
          { task_ids: (1..101).to_a } ].each do |args|
          assert_raises(ArgumentError) { TaskStatusService.new.call(**args) }
        end
        assert_raises(ActiveRecord::RecordNotFound) { TaskStatusService.new.call(task_ids: 999999999) }
        [ { status: "wrong" }, { limit: 0 }, { limit: 101 } ].each do |args|
          assert_raises(ArgumentError) { TopicTasksService.new.call(topic_id: @topic.id, **args) }
        end
      end

      test "requires authenticated readable creative and instruction" do
        task = make_task
        Current.user = nil
        assert_raises(ArgumentError) { TaskStatusService.new.call(task_ids: task.id) }
        assert_raises(ArgumentError) { TopicTasksService.new.call(topic_id: @topic.id) }
        Current.user = @other
        assert_raises(PermissionDeniedError) { TaskStatusService.new.call(task_ids: task.id) }
        assert_raises(PermissionDeniedError) { TaskStatusService.new.call(comment_id: @comment.id) }
        assert_raises(PermissionDeniedError) { TopicTasksService.new.call(topic_id: @topic.id) }
      end

      test "private triggers are hidden from list and status even with creative read access" do
        @comment.update!(private: true, user: @other)
        task = make_task
        assert_empty TopicTasksService.new.call(topic_id: @topic.id)[:tasks]
        assert_raises(ActiveRecord::RecordNotFound) { TaskStatusService.new.call(comment_id: @comment.id) }
        assert_raises(PermissionDeniedError) { TaskStatusService.new.call(task_ids: task.id) }
      end

      test "authorizes each descendant instead of leaking cross creative data" do
        event = SystemEvents::Envelope.root("comment_created")
        root = make_task(payload: payload(event))
        hidden = Creative.create!(description: "Private", user: @other)
        make_task(creative: hidden, payload: payload(SystemEvents::Envelope.child("comment_created", parent: event)).except("comment"))
        assert_raises(PermissionDeniedError) { TaskStatusService.new.call(task_ids: root.id) }
      end

      test "supports legacy payload creative and tasks without a trigger" do
        task = make_task(creative: nil, payload: { "creative" => { "id" => @creative.id } })
        assert_equal "in_progress", TaskStatusService.new.call(task_ids: task.id)[:status]
      end

      test "caps roots and descendants without returning a false done result" do
        event = SystemEvents::Envelope.root("comment_created")
        root = make_task(status: "done", payload: payload(event))
        child_event = SystemEvents::Envelope.child("comment_created", parent: event)
        rows = 200.times.map do
          { name: "Child", agent_id: @owner.id, creative_id: @creative.id, status: "done",
           trigger_comment_id: @comment.id, trigger_event_payload: payload(child_event) }
        end
        Task.insert_all!(rows)
        assert_raises(ArgumentError) { TaskStatusService.new.call(comment_id: @comment.id) }
        assert_raises(ArgumentError) { TaskStatusService.new.call(task_ids: root.id) }
      end

      test "generates parameterized PostgreSQL descendant lookup" do
        connection = Task.connection
        relation = Task.none
        Task.stub(:where, ->(sql, values) {
          assert_equal "trigger_event_payload::jsonb -> 'event' ->> 'causation_id' IN (?)", sql
          assert_equal [ "parent-id" ], values
          relation
        }) do
          connection.stub(:adapter_name, "PostgreSQL") do
            assert_empty TaskDescendants.children([ "parent-id" ])
          end
        end
      end

      test "read share allows polling and listing another owners work" do
        task = make_task
        CreativeShare.create!(creative: @creative, user: @other, permission: :read)
        Current.user = @other
        assert_equal "in_progress", TaskStatusService.new.call(comment_id: @comment.id)[:status]
        assert_equal [ task.id ], TopicTasksService.new.call(topic_id: @topic.id)[:tasks].pluck(:task_id)
      end

      test "a trigger moved to an unreadable creative cannot expose work through its old task" do
        task = make_task
        hidden = Creative.create!(description: "Hidden", user: @other)
        @comment.update_columns(creative_id: hidden.id, topic_id: nil)
        assert_raises(PermissionDeniedError) { TaskStatusService.new.call(task_ids: task.id) }
        assert_empty TopicTasksService.new.call(topic_id: @topic.id)[:tasks]
      end

      private

      def payload(event)
        { "comment" => { "id" => @comment.id }, "event" => event.to_h }
      end

      def make_task(status: "pending", payload: { "comment" => { "id" => @comment.id } }, **attrs)
        Task.create!({ name: "Work", agent: @owner, creative: @creative, topic_id: @topic.id,
          status: status, trigger_event_payload: payload }.merge(attrs))
      end
    end
  end
end
