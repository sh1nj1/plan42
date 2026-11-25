# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentBatchDestructionTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Batch")
      @comments = Array.new(3) { |i| @creative.comments.create!(user: @owner, content: "Message #{i}", skip_dispatch: true) }
      @agent = User.create!(
        email: "batch_destroy_agent@example.com", name: "Batch Agent", password: "password",
        llm_vendor: "google", llm_model: "gemini-1.5-flash", routing_expression: "true", searchable: true
      )
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    test "destroys every comment and returns them" do
      destroyed = Comment.destroy_in_batch(@comments)

      assert_equal @comments.map(&:id), destroyed.map(&:id)
      assert_empty Comment.where(id: @comments.map(&:id))
      assert_equal 0, @creative.reload.comments_count
    end

    test "an empty selection does nothing" do
      assert_equal [], Comment.destroy_in_batch([])
    end

    test "broadcasts all removals in one stream and recounts badges once" do
      @comments.last.update_column(:private, true)
      streams = []
      capture = ->(stream, content:) { streams << [ stream, content ] if stream == [ @creative, :comments ] }

      Turbo::StreamsChannel.stub(:broadcast_stream_to, capture) do
        Turbo::StreamsChannel.stub(:broadcast_remove_to, ->(*, **) { flunk "per-comment remove broadcast" }) do
          assert_enqueued_jobs 1, only: CommentBadgesBroadcastJob do
            Comment.destroy_in_batch(@comments)
          end
        end
      end

      assert_equal 1, streams.size
      stream, content = streams.first
      assert_equal [ @creative, :comments ], stream
      @comments.first(2).each { |comment| assert_includes content, %(target="comment_#{comment.id}") }
      assert_not_includes content, "comment_#{@comments.last.id}"
    end

    test "skips the removal broadcast when every comment is private" do
      @comments.each { |comment| comment.update_column(:private, true) }

      streams = []
      capture = ->(stream, content:) { streams << stream if stream == [ @creative, :comments ] }

      Turbo::StreamsChannel.stub(:broadcast_stream_to, capture) do
        Comment.destroy_in_batch(@comments)
      end
      assert_empty streams
    end

    test "scans active tasks once and cancels only the tasks of deleted comments" do
      doomed = Task.create!(name: "Doomed", status: :pending, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => @comments.first.id } })
      survivor_comment = @creative.comments.create!(user: @owner, content: "Stays", skip_dispatch: true)
      survivor = Task.create!(name: "Survivor", status: :pending, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => survivor_comment.id } })

      source_reads = 0
      read_sources = Comment.method(:dispatch_source_ids)
      counting = ->(task) { source_reads += 1; read_sources.call(task) }
      Comment.stub(:dispatch_source_ids, counting) do
        Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(*) { }) do
          Comment.destroy_in_batch(@comments)
        end
      end

      assert doomed.reload.cancelled?
      assert survivor.reload.pending?
      # Two tasks indexed once, then only the doomed task re-read (match and
      # re-anchor check) for its own comment. Scanning per comment would read
      # both tasks for all three comments.
      assert_equal 4, source_reads
    end

    test "re-anchors a coalesced task past every comment in the batch" do
      keeper = @creative.comments.create!(user: @owner, content: "Keeper", skip_dispatch: true)
      task = Task.create!(name: "Coalesced", status: :queued, agent: @agent, creative: @creative,
        topic_id: @comments.first.topic_id, trigger_event_payload: {
          "comment" => { "id" => @comments.first.id }, "workspace_user_id" => @owner.id,
          "merged_comment_ids" => [ @comments.second.id, keeper.id ]
        })

      Comment.destroy_in_batch(@comments.first(2))

      task.reload
      assert task.queued?
      assert_equal keeper.id, task.trigger_event_payload.dig("comment", "id")
      assert_equal [], task.trigger_event_payload["merged_comment_ids"]
    end

    test "abandons inline logins for the whole batch in one scan" do
      login_task = Task.create!(name: "Login", status: :done, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => @comments.second.id } })
      @comments.first.update_column(:task_id, login_task.id)
      abandoned = []
      calls = 0
      batch_scan = Comment.method(:abandon_pending_logins_for)
      counting = ->(**kwargs) { calls += 1; batch_scan.call(**kwargs) }

      Comment.stub(:abandon_pending_logins_for, counting) do
        CliProxy::InlineLogin.stub(:abandon_replay!, ->(task, pending:) { abandoned << [ task.id, pending ] }) do
          Comment.destroy_in_batch(@comments)
        end
      end

      assert_equal 1, calls
      assert_equal [ [ login_task.id, true ] ], abandoned
    end

    test "a single destroy still abandons its own logins" do
      login_task = Task.create!(name: "Login", status: :done, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => @comments.first.id } })
      abandoned = []

      CliProxy::InlineLogin.stub(:abandon_replay!, ->(task, pending:) { abandoned << task.id }) do
        @comments.first.destroy!
      end

      assert_equal [ login_task.id ], abandoned
    end

    test "a nested call joins the open batch" do
      inner = nil
      outer = Comment.method(:destroy_in_batch)
      @comments.first.define_singleton_method(:destroy) do
        inner = Comment.destroy_in_batch([ Comment.find(Comment.last.id) ])
        super()
      end

      assert_enqueued_jobs 1, only: CommentBadgesBroadcastJob do
        outer.call(@comments.first(1))
      end
      assert_equal 1, inner.size
    end

    test "flushes what was committed even when a callback raises" do
      failing = @comments.last
      failing.define_singleton_method(:cancel_pending_tasks) { raise "boom" }

      assert_enqueued_jobs 1, only: CommentBadgesBroadcastJob do
        assert_raises(RuntimeError) { Comment.destroy_in_batch(@comments) }
      end
      assert_nil Comment.current_batch_destruction
      assert_empty Comment.where(id: @comments.map(&:id))
    end
    test "destroy_later cancels the selection's turns before the job runs" do
      running = Task.create!(name: "Running", status: :running, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => @comments.first.id } })
      login_task = Task.create!(name: "Login", status: :done, agent: @agent, creative: @creative,
        trigger_event_payload: { "comment" => { "id" => @comments.second.id } })
      abandoned = []

      CliProxy::InlineLogin.stub(:abandon_replay!, ->(task, pending:) { abandoned << task.id }) do
        assert_enqueued_jobs 1, only: BatchDestroyCommentsJob do
          Comment.destroy_later(@creative, @comments)
        end
      end

      assert running.reload.cancelled?
      assert_equal [ login_task.id ], abandoned
      assert Comment.where(id: @comments.map(&:id)).all?(&:deleting_at)
      assert_nil Comment.current_batch_destruction
    end

    test "destroy_later re-anchors a coalesced turn onto a comment outside the selection" do
      keeper = @creative.comments.create!(user: @owner, content: "Keeper", skip_dispatch: true)
      task = Task.create!(name: "Coalesced", status: :queued, agent: @agent, creative: @creative,
        topic_id: @comments.first.topic_id, trigger_event_payload: {
          "comment" => { "id" => @comments.first.id }, "workspace_user_id" => @owner.id,
          "merged_comment_ids" => [ @comments.second.id, keeper.id ]
        })

      Comment.destroy_later(@creative, @comments.first(2))

      task.reload
      assert task.queued?
      assert_equal keeper.id, task.trigger_event_payload.dig("comment", "id")
    end

    test "destroy_later restores the markers when the job cannot be enqueued" do
      not_enqueued = BatchDestroyCommentsJob.new
      not_enqueued.successfully_enqueued = false

      BatchDestroyCommentsJob.stub(:perform_later, not_enqueued) do
        assert_raises(ActiveJob::EnqueueError) { Comment.destroy_later(@creative, @comments) }
      end
      assert Comment.where(id: @comments.map(&:id)).all? { |comment| comment.deleting_at.nil? }
    end

    test "destroy_later restores the markers when enqueueing raises" do
      BatchDestroyCommentsJob.stub(:perform_later, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
        assert_raises(ActiveRecord::ConnectionNotEstablished) { Comment.destroy_later(@creative, @comments) }
      end
      assert Comment.where(id: @comments.map(&:id)).all? { |comment| comment.deleting_at.nil? }
    end

    test "destroy_later keeps the scheduled deletion when the broadcast or withdrawal fails" do
      @comments.first.define_singleton_method(:withdraw_dispatch) { raise "withdraw boom" }

      Turbo::StreamsChannel.stub(:broadcast_stream_to, ->(*, **) { raise "cable down" }) do
        assert_enqueued_jobs 1, only: BatchDestroyCommentsJob do
          assert_nothing_raised { Comment.destroy_later(@creative, @comments) }
        end
      end
      assert Comment.where(id: @comments.map(&:id)).all?(&:deleting_at)
      assert_nil Comment.current_batch_destruction
    end
  end
end
