require "test_helper"

# A comment POST decides its dispatch from records and policies read once for
# that dispatch. These pin both halves: the repeated reads are gone, and
# nothing read for one request answers for the next.
class CommentDispatchReuseTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # The test environment runs jobs inline; keep the agent jobs queued so the
  # dispatch decision can be read without running the agent.
  def queue_adapter_for_test
    ActiveJob::QueueAdapters::TestAdapter.new
  end

  setup do
    Collavre::Kollavy.seed!
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    perform_enqueued_jobs do
      @agent = create_agent("reuse-a")
      @other_agent = create_agent("reuse-b")
    end
    @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Reuse", primary_agent_id: @agent.id)
    clear_enqueued_jobs
  end

  test "the orchestrator reads context policies once and does not re-read the comment, author or topic" do
    queries = orchestrator_queries { post_comment("measure") }

    assert_equal [ @agent.id ], dispatched_agent_ids
    # One read for the context policies, one for the routed agent's own.
    assert_equal 2, queries.grep(/FROM "orchestrator_policies"/).size
    assert_empty queries.grep(/FROM "comments" WHERE "comments"\."id" = \?/)
    assert_empty queries.grep(/SELECT "topics"\."primary_agent_id"/)
    assert_equal 1, queries.grep(/FROM "topics" WHERE "topics"\."id" = \?/).size
    # The routed agent; the author was already loaded by the comment.
    assert_equal 1, queries.grep(/FROM "users" WHERE "users"\."id" = \?/).size
  end

  test "a topic pin changed between requests routes the next comment to the new agent" do
    post_comment("first")
    assert_equal [ @agent.id ], dispatched_agent_ids

    @topic.update!(primary_agent_id: @other_agent.id)
    clear_enqueued_jobs
    post_comment("second")

    assert_equal [ @other_agent.id ], dispatched_agent_ids
  end

  test "context and agent policies changed between requests apply to the next comment" do
    post_comment("allowed")
    assert_equal [ @agent.id ], dispatched_agent_ids

    topic_policy = Collavre::OrchestratorPolicy.create!(
      policy_type: "scheduling", scope_type: "Topic", scope_id: @topic.id, config: { "daily_token_limit" => 0 }
    )
    clear_enqueued_jobs
    post_comment("blocked by topic policy")
    assert_empty dispatched_agent_ids

    topic_policy.update!(enabled: false)
    agent_policy = Collavre::OrchestratorPolicy.create!(
      policy_type: "scheduling", scope_type: "User", scope_id: @agent.id, config: { "daily_token_limit" => 0 }
    )
    clear_enqueued_jobs
    post_comment("blocked by agent policy")
    assert_empty dispatched_agent_ids

    agent_policy.destroy!
    clear_enqueued_jobs
    post_comment("allowed again")
    assert_equal [ @agent.id ], dispatched_agent_ids
  end

  test "an arbitration policy changed between requests applies to the next comment" do
    @topic.update!(primary_agent_id: nil)
    Collavre::OrchestratorPolicy.create!(
      policy_type: "scheduling", scope_type: "Topic", scope_id: @topic.id, config: { "topic_max_concurrent_jobs" => 5 }
    )
    post_comment("both")
    assert_equal [ @agent.id, @other_agent.id ], dispatched_agent_ids.sort

    Collavre::OrchestratorPolicy.create!(
      policy_type: "arbitration", scope_type: "Creative", scope_id: @creative.id, config: { "max_responders" => 1 }
    )
    clear_enqueued_jobs
    post_comment("one")

    assert_equal [ @agent.id ], dispatched_agent_ids
  end

  test "the sender is read for each request" do
    post_comment("before rename")
    assert_equal @user.name, dispatched_payloads.last.dig("sender", "name")

    @user.update!(name: "Renamed Author")
    clear_enqueued_jobs
    post_comment("after rename")

    assert_equal "Renamed Author", dispatched_payloads.last.dig("sender", "name")
  end

  private

  def create_agent(handle)
    agent = User.create!(
      email: "#{handle}@test.local", password: "password123", name: handle.titleize,
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true, routing_expression: "true",
      created_by_id: @user.id
    )
    Collavre::CreativeShare.create!(creative: @creative, user: agent, shared_by: @user, permission: :feedback)
    agent
  end

  def post_comment(content)
    post creative_comments_path(@creative), params: { comment: { content: content, topic_id: @topic.id } }
    assert_response :created
  end

  def agent_jobs
    enqueued_jobs.select { |job| job["job_class"] == "Collavre::AiAgentJob" }
  end

  def dispatched_arguments
    agent_jobs.map { |job| ActiveJob::Arguments.deserialize(job["arguments"]) }
  end

  def dispatched_agent_ids
    dispatched_arguments.map(&:first)
  end

  def dispatched_payloads
    dispatched_arguments.map(&:third)
  end

  # SQL issued while the comment dispatches to orchestration, cache hits
  # included: a repeated lookup is what is being counted, wherever it lands.
  def orchestrator_queries
    queries = []
    dispatching = false
    callback = lambda do |*, payload|
      queries << payload[:sql] if dispatching && payload[:name] != "SCHEMA"
    end
    track = lambda do |*args, **options, &block|
      dispatching = true
      Collavre::SystemEvents::Dispatcher.new.dispatch(*args, **options, &block)
    ensure
      dispatching = false
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, track) { yield }
    end
    queries
  end
end
