# frozen_string_literal: true

require "test_helper"

class CreativesControllerTriggerTaskTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")

    @trigger_parent = Collavre::Creative.create!(
      user: @user,
      description: "Trigger Container",
      data: { "trigger" => { "on_child_enter" => true } }
    )
    @normal_parent = Collavre::Creative.create!(
      user: @user,
      description: "Normal Parent"
    )
  end

  test "show JSON returns is_trigger_task true for child of trigger container" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "Trigger Task Child"
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["is_trigger_task"]
  end

  test "show JSON returns is_trigger_task true even without loop state" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "New Trigger Task"
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["is_trigger_task"]
    assert_nil json["trigger_loop"]
  end

  test "show JSON returns is_trigger_task false for child of normal parent" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @normal_parent,
      description: "Normal Child"
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal false, json["is_trigger_task"]
  end

  test "show JSON returns is_trigger_task false for root creative" do
    get creative_path(@trigger_parent), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal false, json["is_trigger_task"]
  end

  test "show JSON returns is_trigger_task true with existing loop state" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "Running Task",
      data: { "trigger" => { "loop" => { "state" => "running", "current_iteration" => 3, "max_iterations" => 10 } } }
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["is_trigger_task"]
    assert_equal "running", json["trigger_loop"]["state"]
  end

  test "trigger_action start enqueues DropTriggerJob for idle trigger task" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "Start Me"
    )

    prev_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    begin
      clear_enqueued_jobs
      assert_enqueued_with(job: Collavre::DropTriggerJob) do
        patch trigger_action_creative_path(child),
              params: { action_name: "start" },
              headers: { "ACCEPT" => "application/json", "CONTENT_TYPE" => "application/json" },
              as: :json
      end
      assert_response :success
    ensure
      ActiveJob::Base.queue_adapter = prev_adapter
    end
  end

  test "trigger_action start rejects non-trigger-container child" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @normal_parent,
      description: "Not Trigger"
    )

    patch trigger_action_creative_path(child),
          params: { action_name: "start" },
          headers: { "ACCEPT" => "application/json", "CONTENT_TYPE" => "application/json" },
          as: :json

    assert_response :unprocessable_entity
  end
  test "linked keep status and controls use the origin without modifying shell data" do
    origin = @normal_parent
    origin.update!(data: { "trigger" => { "loop" => Collavre::TriggerLoopConfig.build(
      origin.main_topic.id, source: "keep", state: "running", goal: "Finish work"
    ) } })
    shell = Collavre::Creative.create!(user: @user, origin: origin, data: { "shell" => true })

    get creative_path(shell), as: :json
    assert_response :success
    assert_equal "running", response.parsed_body.dig("trigger_loop", "state")
    etag = response.headers["ETag"]
    patch trigger_action_creative_path(shell), params: { action_name: "pause" }, as: :json
    assert_response :success
    assert_equal "paused", origin.reload.data.dig("trigger", "loop", "state")
    get creative_path(shell), headers: { "If-None-Match" => etag }, as: :json
    assert_response :success
    assert_equal "paused", response.parsed_body.dig("trigger_loop", "state")

    dispatched = []
    Collavre::SystemEvents::Dispatcher.stub(:dispatch, lambda { |_event, payload, **_options|
      dispatched << payload
      [ users(:ai_bot) ]
    }) do
      patch trigger_action_creative_path(shell), params: { action_name: "resume" }, as: :json
      assert_response :success
      assert_equal "running", origin.reload.data.dig("trigger", "loop", "state")
      origin.update!(data: origin.data.deep_merge("trigger" => { "loop" => { "state" => "completed" } }))
      patch trigger_action_creative_path(shell), params: { action_name: "restart" }, as: :json
      assert_response :success
      assert_equal "running", origin.reload.data.dig("trigger", "loop", "state")
    end
    assert_equal 2, dispatched.size
    assert_equal 2, origin.comments.count
    assert origin.comments.all? { |comment| comment.topic_id == origin.main_topic.id }
    assert_equal({ "shell" => true }, shell.reload.data)
    assert_empty shell.comments
  end

  test "linked keep controls require write permission on the origin" do
    origin = Collavre::Creative.create!(user: users(:two), description: "Shared origin",
      data: { "trigger" => { "loop" => { "source" => "keep", "state" => "running" } } })
    Collavre::CreativeShare.create!(creative: origin, user: @user, permission: :read)
    shell = Collavre::Creative.create!(user: @user, origin: origin)
    patch trigger_action_creative_path(shell), params: { action_name: "pause" }, as: :json
    assert_response :forbidden
    assert_equal "running", origin.reload.data.dig("trigger", "loop", "state")
  end
end
