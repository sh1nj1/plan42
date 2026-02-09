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
