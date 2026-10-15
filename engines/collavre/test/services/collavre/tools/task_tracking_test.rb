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

      test "preserves original instruction when payload anchor changes" do
        task = make_task
        assert_equal @comment.id, task.trigger_comment_id
        task.update!(trigger_event_payload: {})
        assert_equal @comment.id, task.reload.trigger_comment_id
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
        rows.each { |row| row[:event_causation_id] = event.id }
        Task.insert_all!(rows)
        assert_raises(ArgumentError) { TaskStatusService.new.call(comment_id: @comment.id) }
        assert_raises(ArgumentError) { TaskStatusService.new.call(task_ids: root.id) }
      end

      test "updates the indexed causation when the envelope changes" do
        event = SystemEvents::Envelope.root("comment_created")
        task = make_task(payload: payload(event.with(causation_id: "parent-id")))
        assert_equal [ task.id ], TaskDescendants.children([ "parent-id" ]).pluck(:id)
        task.update!(trigger_event_payload: {})
        assert_nil task.reload.event_causation_id
        assert_empty TaskDescendants.children([ "parent-id" ])
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

      test "follows superseded tasks to a running and then completed survivor" do
        original = make_task(status: "queued")
        replacement = make_task(status: "queued")
        Orchestration::TaskCoalescer.coalesce!(replacement)
        assert original.reload.cancelled?
        result = TaskStatusService.new.call(task_ids: original.id)
        assert_equal "in_progress", result[:status]
        assert_equal replacement.id, result[:tasks].find { |row| row[:task_id] == original.id }[:superseded_by_task_id]
        replacement.update!(status: "done")
        assert_equal "done", TaskStatusService.new.call(task_ids: original.id)[:status]
        assert_equal "done", TaskStatusService.new.call(comment_id: @comment.id)[:status]
      end

      test "finds reanchored and historical merged instructions" do
        task = make_task
        replacement = @topic.comments.create!(creative: @creative, user: @owner, content: "Next", skip_dispatch: true)
        context = Orchestration::TaskCoalescer.absorb_into_payload(
          Orchestration::TaskCoalescer.reanchor_payload(task.trigger_event_payload, replacement), [ @comment.id ])
        task.update!(trigger_event_payload: context)
        assert_equal @comment.id, task.reload.trigger_comment_id
        assert_equal [ task.id ], TaskStatusService.new.call(comment_id: @comment.id)[:tasks].pluck(:task_id)
        # A legacy backfill only knows the current anchor; JSON retains the original.
        task.update_columns(trigger_comment_id: replacement.id)
        assert_equal "in_progress", TaskStatusService.new.call(comment_id: @comment.id)[:status]
      end

      test "invalid or missing replacement targets never report done" do
        task = make_task(status: "cancelled")
        action = task.task_actions.create!(action_type: "superseded", status: "done",
          payload: { "superseded_by_task_id" => 999999999 })
        assert_raises(ActiveRecord::RecordNotFound) { TaskStatusService.new.call(task_ids: task.id) }
        action.update!(payload: {})
        assert_raises(ActiveRecord::RecordNotFound) { TaskStatusService.new.call(task_ids: task.id) }
        action.update!(payload: { "superseded_by_task_id" => task.id })
        assert_raises(ArgumentError) { TaskStatusService.new.call(task_ids: task.id) }
      end

      test "combines indexed roots and historical merged instructions" do
        root = make_task(status: "done")
        legacy = make_task(payload: { "merged_comment_ids" => [ @comment.id ] })
        assert_equal "in_progress", TaskStatusService.new.call(comment_id: @comment.id)[:status]
        assert_equal [ root.id, legacy.id ].sort, TaskLineage.for_comment(@comment.id).pluck(:id).sort
        legacy.update!(trigger_event_payload: {})
        assert_empty TaskMergedInstruction.where(task_id: legacy.id)
      end

      test "legacy payload creative resolves a visible reply" do
        task = make_task(creative: nil, payload: { "creative" => { "id" => @creative.id } })
        reply = @topic.comments.create!(creative: @creative, user: @owner, content: "Ready", task_id: task.id, skip_dispatch: true)
        assert_equal reply.id, TaskStatusService.new.call(task_ids: task.id)[:tasks].sole[:reply_comment_id]
      end

      test "descendant query uses the causation expression index" do
        assert Task.connection.indexes(:tasks).any? { |index| index.name == "index_tasks_on_event_causation_id" }
        unless Task.connection.adapter_name == "PostgreSQL"
          plan = Task.connection.execute("EXPLAIN QUERY PLAN #{TaskDescendants.children([ 'parent-id' ]).to_sql}")
          assert_includes plan.map { |row| row["detail"] }.join, "index_tasks_on_event_causation_id"
        end
      end

      test "batch authorization does not query triggers once per task" do
        tasks = 10.times.map { make_task }
        queries = []
        subscriber = ->(_name, _start, _finish, _id, data) { queries << data[:sql] if data[:sql].match?(/SELECT.*comments/i) }
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          TaskTracking.authorize_all!(tasks, @owner)
        end
        assert_equal 1, queries.size
      end

      test "merged instruction index backfills historical payloads and cleans up deleted tasks" do
        require Rails.root.join("engines/collavre/db/migrate/20261016000002_index_task_merged_instructions")
        task = make_task
        task.update_columns(trigger_event_payload: { "merged_comment_ids" => [ @comment.id.to_s, @comment.id, nil, "invalid" ] })
        migration = IndexTaskMergedInstructions.new
        migration.stub(:create_table, ->(*) { }) { migration.up }
        assert_equal [ task.id ], TaskLineage.for_comment(@comment.id).pluck(:id)
        assert_equal 1, TaskMergedInstruction.where(task_id: task.id).count
        task.destroy!
        assert_empty TaskMergedInstruction.where(task_id: task.id)
        migration.stub(:drop_table, ->(table) { assert_equal :task_merged_instructions, table }) { migration.down }
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
