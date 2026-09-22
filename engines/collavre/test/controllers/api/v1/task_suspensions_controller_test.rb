require "test_helper"

class TaskSuspensionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @owner = users(:one)
    @agent = users(:ai_bot)
    @agent.update!(created_by_id: @owner.id, llm_vendor: "anthropic", llm_model: "claude-code")
    @creative = creatives(:tshirt)
    @creative.update!(user: @owner)
    @task = Collavre::Task.create!(name: "Suspension API", agent: @agent, creative: @creative,
                                 status: "delegated", trigger_event_payload: { "execution_generation" => "current" })
    application = Doorkeeper::Application.create!(name: "Quota", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", scopes: "public", owner: @owner)
    @token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: @owner.id, scopes: "public")
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "owner suspends current execution and duplicate request is idempotent" do
    suspend
    assert_response :ok
    deadline = @task.reload.resume_not_before
    suspend
    assert_response :ok
    assert_equal deadline, @task.reload.resume_not_before
    assert_equal 1, @agent.reload.quota_retry_count
  end

  test "missing or stale generation cannot suspend even a delegated row" do
    [ nil, "old" ].each do |generation|
      suspend(generation: generation)
      assert_response :conflict
      assert_equal "delegated", @task.reload.status
    end
  end

  test "foreign agent and non channel tasks are inaccessible" do
    @agent.update!(created_by_id: users(:two).id)
    suspend
    assert_response :not_found
    @agent.update!(created_by_id: @owner.id, llm_vendor: "openai", llm_model: "gpt-4o")
    suspend
    assert_response :not_found
  end

  test "completed task and invalid reason are rejected" do
    suspend(reason: "server_restart")
    assert_response :unprocessable_entity
    @task.update!(status: "done")
    suspend
    assert_response :conflict
  end

  test "requires authentication" do
    post "/api/v1/agent/tasks/#{@task.id}/suspend", params: { reason: "quota", execution_generation: "current" }, as: :json
    assert_response :unauthorized
  end

  test "owning the agent does not grant permission to a private creative" do
    private_creative = Collavre::Creative.create!(description: "Other owner", user: users(:two))
    @task.update!(creative: private_creative)
    suspend
    assert_response :not_found
    assert_equal "delegated", @task.reload.status
  end

  test "a retired execution cannot suspend the next delegated attempt" do
    suspend
    assert_response :ok
    @task.reload.update!(status: "delegated", trigger_event_payload: { "execution_generation" => "next" })
    suspend
    assert_response :conflict
    assert_equal "delegated", @task.reload.status
    assert_equal 1, @agent.reload.quota_retry_count
  end

  test "quota status prunes terminal and retired turns without changing server state" do
    %w[delegated running pending_approval cancelled failed done].each do |status|
      @task.update!(status: status)
      quota_status
      assert_response :ok
      assert_equal %w[delegated running pending_approval].include?(status), response.parsed_body["current"]
      assert_equal status, @task.reload.status
    end
    @task.update!(status: "delegated")
    quota_status(generation: "old")
    assert_equal false, response.parsed_body["current"]
    quota_status(generation: nil)
    assert_equal false, response.parsed_body["current"]
    suspend
    quota_status
    assert_equal true, response.parsed_body["current"]
  end

  test "quota status requires authentication ownership and creative access" do
    get "/api/v1/agent/tasks/#{@task.id}/quota_status"
    assert_response :unauthorized
    @agent.update!(created_by_id: users(:two).id)
    quota_status
    assert_response :not_found
    @agent.update!(created_by_id: @owner.id)
    @task.update!(creative: Collavre::Creative.create!(description: "Private", user: users(:two)))
    quota_status
    assert_response :not_found
  end

  private

  def quota_status(generation: "current")
    get "/api/v1/agent/tasks/#{@task.id}/quota_status",
        params: { execution_generation: generation },
        headers: { "Authorization" => "Bearer #{@token.token}" }, as: :json
  end

  def suspend(generation: "current", reason: "quota")
    post "/api/v1/agent/tasks/#{@task.id}/suspend",
         params: { reason: reason, execution_generation: generation, retry_after: "3600" },
         headers: { "Authorization" => "Bearer #{@token.token}" }, as: :json
  end
end
