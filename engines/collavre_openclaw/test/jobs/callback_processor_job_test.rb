require "test_helper"

module CollavreOpenclaw
  class CallbackProcessorJobTest < ActiveJob::TestCase
    setup do
      @user = User.create!(
        email: "job-test@example.com",
        password: "password123",
        name: "Test Bot",
        gateway_url: "https://test-gateway.com"
      )

      # Create a creative for testing
      @owner = User.create!(
        email: "creative-owner@example.com",
        password: "password123",
        name: "Creative Owner"
      )
      @creative = Collavre::Creative.create!(
        description: "Test Creative",
        user: @owner
      )
    end

    teardown do
      Collavre::Comment.where(creative: @creative).destroy_all
      Collavre::ProcessedAiRun.where(run_id: %w[run-aaa run-bbb run-ccc run-folded run-camel]).delete_all
      @creative&.destroy
      @user&.destroy
      @owner&.destroy
    end

    test "skips processing for non-existent user" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(999999, { "type" => "response" })
      end
    end

    test "handles response type payload" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@user.id, {
          "type" => "response",
          "content" => "AI response content",
          "context" => { "task_id" => 123 }
        })
      end
    end

    test "handles error type payload" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@user.id, {
          "type" => "error",
          "error" => "Something went wrong"
        })
      end
    end

    test "handles unknown callback type gracefully" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@user.id, {
          "type" => "unknown_type",
          "data" => "some data"
        })
      end
    end

    test "processes payload with string keys" do
      assert_nothing_raised do
        CallbackProcessorJob.perform_now(@user.id, {
          "type" => "response",
          "content" => "Response with string keys"
        })
      end
    end

    test "creates comment for proactive message" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "This is a proactive message from OpenClaw!"
      })

      assert_equal before_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
      assert_equal @user, comment.user
      assert_equal @creative, comment.creative
      assert_equal "This is a proactive message from OpenClaw!", comment.content
    end

    test "creates comment for proactive message with nested context" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "context" => { "creative_id" => @creative.id },
        "message" => "Proactive message via context"
      })

      assert_equal before_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
      assert_equal "Proactive message via context", comment.content
    end

    test "creates comment in topic when proactive payload uses topic_id" do
      topic = Collavre::Topic.create!(creative: @creative, user: @owner, name: "Talk to Vrex")

      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "topic_id" => topic.id,
        "content" => "Topic scoped proactive message"
      })

      assert_equal before_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
      assert_equal topic, comment.topic
      assert_equal "Topic scoped proactive message", comment.content
    end

    test "creates response comment in topic when context uses topic_id" do
      topic = Collavre::Topic.create!(creative: @creative, user: @owner, name: "Talk to Vrex")

      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "response",
        "content" => "Async response in topic",
        "context" => { "creative_id" => @creative.id, "topic_id" => topic.id }
      })

      assert_equal before_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
      assert_equal topic, comment.topic
      assert_equal "Async response in topic", comment.content
    end

    test "proactive message without creative_id logs error" do
      before_count = Collavre::Comment.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "content" => "Missing creative_id"
      })
      assert_equal before_count, Collavre::Comment.count
    end

    test "proactive message without content logs error" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id
      })
      assert_equal before_count, @creative.comments.reload.count
    end

    test "response with creative_id creates new comment" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "response",
        "content" => "Async response to creative",
        "context" => { "creative_id" => @creative.id }
      })
      assert_equal before_count + 1, @creative.comments.reload.count
    end

    test "error with creative_id creates error comment" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "error",
        "error" => "API limit exceeded",
        "context" => { "creative_id" => @creative.id }
      })

      assert_equal before_count + 1, @creative.comments.reload.count
      comment = @creative.comments.order(:id).last
      assert_includes comment.content, "OpenClaw Error"
      assert_includes comment.content, "API limit exceeded"
    end

    # --- Dedup tests ---

    test "duplicate proactive message within DEDUP_WINDOW is skipped" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Duplicate test message"
      })
      assert_equal before_count + 1, @creative.comments.reload.count

      # Second identical message within the dedup window should be skipped
      count_after_first = @creative.comments.reload.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Duplicate test message"
      })
      assert_equal count_after_first, @creative.comments.reload.count
    end

    test "same user different content still creates comment" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "First message"
      })
      assert_equal before_count + 1, @creative.comments.reload.count

      count_after_first = @creative.comments.reload.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Different message"
      })
      assert_equal count_after_first + 1, @creative.comments.reload.count
    end

    # --- run_id idempotency (cross-process duplicate suppression) ---

    test "proactive message persists openclaw_run_id on the comment" do
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Run-keyed proactive message",
        "run_id" => "run-aaa"
      })

      comment = @creative.comments.reload.order(:id).last
      assert_equal "run-aaa", comment.openclaw_run_id
    end

    test "proactive message honors the Gateway camelCase runId field" do
      # The Gateway emits camelCase `runId`; the HTTP CallbacksController path
      # forwards the raw Gateway payload, so the job must read it even when the
      # snake_case `run_id` is absent. Otherwise the dedup key is dropped and a
      # cross-path duplicate slips through.
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "camelCase run-keyed proactive message",
        "runId" => "run-camel"
      })

      comment = @creative.comments.reload.order(:id).last
      assert_equal "run-camel", comment.openclaw_run_id
    end

    test "duplicate run_id is suppressed even with different content and past content window" do
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "First arrival of this run",
        "run_id" => "run-bbb"
      })
      count_after_first = @creative.comments.reload.count
      first = @creative.comments.order(:id).last

      # Different content (so the 5s content-based dedup would NOT catch it)
      # simulating another process classifying the same run as proactive.
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Second arrival, different framing",
        "run_id" => "run-bbb"
      })

      assert_equal count_after_first, @creative.comments.reload.count
      assert_equal first.id, @creative.comments.order(:id).last.id
    end

    test "proactive skips when a comment already claimed the run_id (solicited path won)" do
      # Simulate the solicited reply comment that already backfilled the run_id.
      solicited = @creative.comments.create!(
        user: @user,
        content: "Solicited reply with activity log",
        openclaw_run_id: "run-ccc"
      )
      count_before = @creative.comments.reload.count

      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Proactive duplicate of the solicited run",
        "run_id" => "run-ccc"
      })

      assert_equal count_before, @creative.comments.reload.count
      assert_equal solicited.id, @creative.comments.where(openclaw_run_id: "run-ccc").sole.id
    end

    test "proactive is suppressed when the run is recorded in the tombstone but no comment holds it" do
      # Simulates the review workflow: the solicited reply that owned the run_id
      # was folded into its quoted comment and destroyed, so NO comment carries
      # the run_id — only the durable ProcessedAiRun tombstone remains.
      Collavre::ProcessedAiRun.record("run-folded")
      count_before = @creative.comments.reload.count

      result = CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Late re-delivery of a folded run",
        "run_id" => "run-folded"
      })

      assert_nil result, "no comment is created for an already-processed run"
      assert_equal count_before, @creative.comments.reload.count
    end

    test "proactive without run_id still creates a comment" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "proactive",
        "creative_id" => @creative.id,
        "content" => "Keyless proactive message"
      })
      assert_equal before_count + 1, @creative.comments.reload.count
      assert_nil @creative.comments.order(:id).last.openclaw_run_id
    end

    test "non-duplicate response messages create comments normally" do
      before_count = @creative.comments.count
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "response",
        "content" => "Response A",
        "context" => { "creative_id" => @creative.id }
      })
      CallbackProcessorJob.perform_now(@user.id, {
        "type" => "response",
        "content" => "Response B",
        "context" => { "creative_id" => @creative.id }
      })
      assert_equal before_count + 2, @creative.comments.reload.count
    end
  end
end
