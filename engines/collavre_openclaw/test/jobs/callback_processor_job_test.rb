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
