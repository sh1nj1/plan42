# frozen_string_literal: true

require "test_helper"

class ApprovalGateControllerTest < ActionDispatch::IntegrationTest
  setup do
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user = users(:one)
    @creative = creatives(:tshirt)
    @creative.update!(user: @user)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    @task = Collavre::Task.create!(name: "Approval", status: "pending_approval", agent: users(:ai_bot),
      creative: @creative, topic_id: @creative.main_topic.id,
      pending_tool_call: { kind: "approval_gate", tool_call_id: "gate-1" })
    @comment = @creative.comments.create!(user: @task.agent, approver: @user,
      topic_id: @task.topic_id, content: "Proceed?",
      action: { action: "approval_gate", task_id: @task.id, tool_call_id: "gate-1" }.to_json)
  end

  teardown do
    ActiveJob::Base.queue_adapter = @old_adapter
  end

  test "pending gate renders approve deny and optional reason without editable action" do
    get creative_comments_path(@creative), params: { topic_id: @task.topic_id }
    assert_response :success
    assert_select "#comment_#{@comment.id}[data-approval-gate=true]" do
      assert_select ".approve-comment-btn", count: 1
      assert_select ".deny-comment-btn", count: 1
      assert_select "textarea[data-approval-reason]", count: 1
      assert_select ".edit-comment-action-btn", count: 0
    end
  end

  test "Claude approval request renders as an approver-only gate" do
    @comment.update!(action: { action: "claude_channel_permission", kind: "approval_request", request_id: "claude-gate" }.to_json)
    get creative_comments_path(@creative), params: { topic_id: @task.topic_id }
    assert_response :success
    assert_select "#comment_#{@comment.id}[data-approval-gate=true]" do
      assert_select ".approve-comment-btn", count: 1
      assert_select ".deny-comment-btn", count: 1
      assert_select "textarea[data-approval-reason]", count: 1
    end
  end

  %w[approve deny].each do |action|
    test "#{action} records reason and returns decided UI once" do
      assert_enqueued_with(job: Collavre::ApprovalGateResumeJob) do
        post "/creatives/#{@creative.id}/comments/#{@comment.id}/#{action}", params: { reason: "<script>reason</script>" }, as: :json
      end
      assert_response :success
      assert_select action == "deny" ? ".denied-label" : ".approved-label", count: 1
      assert_select "script", count: 0
      assert_select "textarea[data-approval-reason]", count: 0
      assert_equal "<script>reason</script>", @comment.reload.approval_gate_reason
      assert_equal @user.id, @task.reload.pending_tool_call.dig("decision", "decided_by")
      post "/creatives/#{@creative.id}/comments/#{@comment.id}/#{action}", as: :json
      assert_response :unprocessable_entity
    end
  end

  test "non-approver cannot decide and approval payload cannot be edited" do
    @comment.update!(approver: users(:two))
    post "/creatives/#{@creative.id}/comments/#{@comment.id}/approve", as: :json
    assert_response :forbidden
    post "/creatives/#{@creative.id}/comments/#{@comment.id}/deny", as: :json
    assert_response :forbidden
    patch "/creatives/#{@creative.id}/comments/#{@comment.id}/update_action", params: { comment: { action: '{"action":"execute_tool"}' } }, as: :json
    assert_response :forbidden
    assert_nil @comment.reload.action_executed_at
  end

  test "cancelled task rejects late response" do
    @task.update!(status: "cancelled")
    post "/creatives/#{@creative.id}/comments/#{@comment.id}/deny", as: :json
    assert_response :unprocessable_entity
    assert_nil @comment.reload.action_executed_at
  end
end
