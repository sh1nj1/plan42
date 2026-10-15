# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentBulkFollowUpJobsTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    def queue_adapter_for_test
      ActiveJob::QueueAdapters::SolidQueueAdapter.new
    end

    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      Current.session = OpenStruct.new(user: @user)
      @agent = User.create!(
        email: "bulk_follow_up_agent@agent.collavre.local",
        name: "Bulk Follow Up Agent",
        password: "password",
        llm_vendor: "anthropic",
        llm_model: "claude-sonnet",
        routing_expression: "true",
        created_by_id: @user.id
      )
      CreativeShare.find_or_create_by!(creative: @creative, user: @agent).update!(permission: "feedback")
      CreativeSharesCache.find_or_create_by!(creative_id: @creative.id, user_id: @agent.id, permission: :feedback)
      # Warm up schema caches so only steady-state queue statements are counted.
      post_comment("warm up https://example.com")
    end

    teardown do
      Current.reset
    end

    test "a new comment writes its follow-up jobs in bulk, in the original order and with the original arguments" do
      unbatched = capture_queue_writes { without_bulk_enqueue { post_comment("unbatched https://example.com @Two") } }
      batched = capture_queue_writes { post_comment("batched https://example.com @Two") }

      expected_classes = %w[
        Turbo::Streams::ActionBroadcastJob Collavre::CommentBadgesBroadcastJob
        Collavre::CommentNotificationJob Collavre::CommentLinkPreviewJob Collavre::AiAgentJob
      ]
      assert_equal expected_classes, unbatched[:jobs].map(&:class_name)
      assert_equal expected_classes, batched[:jobs].map(&:class_name)
      assert_equal unbatched[:jobs].map(&:queue_name), batched[:jobs].map(&:queue_name)
      assert_equal unbatched[:jobs].map(&:priority), batched[:jobs].map(&:priority)
      assert_equal normalized_arguments(unbatched), normalized_arguments(batched)
      assert(batched[:jobs].all?(&:ready_execution))

      assert_equal 5, unbatched[:transactions]
      # The agent dispatch needs its enqueue result, so it flushes the four
      # pending fire-and-forget jobs together with itself.
      assert_equal 1, batched[:transactions]
      assert_operator batched[:queries], :<, unbatched[:queries]
    end

    test "the agent dispatch still gets a real enqueue acknowledgement" do
      acked = []
      original = AiAgentJob.method(:perform_later)
      AiAgentJob.stub(:perform_later, ->(*args) { original.call(*args).tap { |job| acked << [ job.successfully_enqueued?, job.provider_job_id.present? ] } }) do
        post_comment("needs an agent")
      end

      assert_equal [ [ true, true ] ], acked
    end

    test "editing a comment writes its follow-up jobs in one bulk insert" do
      comment = post_comment("before edit")
      writes = capture_queue_writes { comment.update!(content: "after edit https://example.com") }

      assert_equal %w[Turbo::Streams::ActionBroadcastJob Collavre::CommentLinkPreviewJob], writes[:jobs].map(&:class_name)
      assert_equal 1, writes[:transactions]
    end

    test "jobs are only written after the comment's transaction commits" do
      writes = capture_queue_writes do
        Comment.transaction do
          post_comment("rolled back https://example.com")
          raise ActiveRecord::Rollback
        end
      end

      assert_empty writes[:jobs]
      assert_equal 0, writes[:queries]
    end

    test "a failing after_commit callback still writes the jobs enqueued before it" do
      writes = capture_queue_writes do
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise "dispatch failed" }) do
          assert_raises(RuntimeError) { post_comment("dispatch fails https://example.com") }
        end
      end

      assert_equal %w[
        Turbo::Streams::ActionBroadcastJob Collavre::CommentBadgesBroadcastJob
        Collavre::CommentNotificationJob Collavre::CommentLinkPreviewJob
      ], writes[:jobs].map(&:class_name)
      assert_nil BulkJobEnqueue.current
    end

    private

    def post_comment(content)
      @creative.comments.create!(content: content, user: @user)
    end

    def without_bulk_enqueue(&block)
      BulkJobEnqueue.stub(:collect, ->(**, &inner) { inner.call }, &block)
    end

    # Counts the statements Solid Queue issues while writing jobs. Write
    # transactions are the outermost savepoints here because the test itself
    # runs inside a transaction; in production each is a BEGIN/COMMIT pair.
    def capture_queue_writes
      baseline_id = SolidQueue::Job.maximum(:id).to_i
      statements = []
      depth = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] if depth.positive?
      end
      track = lambda do |original|
        lambda do |*args, **kwargs|
          depth += 1
          original.call(*args, **kwargs)
        ensure
          depth -= 1
        end
      end
      result = SolidQueue::Job.stub(:enqueue, track.call(SolidQueue::Job.method(:enqueue))) do
        SolidQueue::Job.stub(:enqueue_all, track.call(SolidQueue::Job.method(:enqueue_all))) { yield }
      end

      {
        result: result,
        jobs: SolidQueue::Job.where("id > ?", baseline_id).order(:id).to_a,
        queries: statements.size,
        transactions: statements.count { |sql| sql.start_with?("SAVEPOINT active_record_1") }
      }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Two different comments: blank out what legitimately differs between them
    # (record id, content prefix, per-event id and timestamp).
    def normalized_arguments(writes)
      comment = writes[:result]
      writes[:jobs].map do |job|
        job.arguments["arguments"].to_json
          .gsub(/(?<![\w.])#{comment.id}(?![\w.])/, "COMMENT_ID")
          .gsub(/"(?:un)?batched /, '"')
          .gsub(/"(id|correlation_id|occurred_at)":"[^"]*"/, '"\\1":"X"')
      end
    end
  end
end
