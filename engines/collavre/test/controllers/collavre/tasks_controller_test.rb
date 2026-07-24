# frozen_string_literal: true

require "test_helper"

module Collavre
  class TasksControllerTest < ActionDispatch::IntegrationTest
    setup do
      @owner = users(:one)
      @stranger = users(:two)
      @agent = User.create!(
        email: "tasks_controller_agent@example.com",
        name: "Status Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )
      @creative = Creative.create!(user: @owner, description: "Owner Creative")
    end

    def build_task(status: "running", creative: @creative, linked: true)
      Task.create!(
        name: "Response to comment_created",
        status: status,
        trigger_event_name: "comment_created",
        trigger_event_payload: { "creative" => { "id" => creative.id } },
        agent: @agent,
        creative: (creative if linked)
      )
    end

    def statuses_for(task_ids)
      get collavre.active_statuses_tasks_path(task_ids: Array(task_ids).join(","))
      assert_response :success
      JSON.parse(response.body)["tasks"]
    end

    test "returns statuses for tasks on a creative the user can read" do
      task = build_task

      sign_in_as(@owner, password: "password")

      assert_equal [{ "id" => task.id, "status" => "running" }], statuses_for(task.id)
    end

    test "omits tasks on creatives the user cannot read" do
      task = build_task

      sign_in_as(@stranger, password: "password")

      assert_empty statuses_for(task.id)
    end

    # The endpoint takes ids straight from the query string, so an authenticated
    # user can enumerate them. Leaking only the readable subset — rather than
    # everything asked for — is what keeps that enumeration worthless.
    test "returns only the readable subset when a request mixes readable and foreign task ids" do
      mine = build_task
      theirs = build_task(creative: Creative.create!(user: @stranger, description: "Stranger Creative"))

      sign_in_as(@owner, password: "password")

      assert_equal [mine.id], statuses_for([mine.id, theirs.id]).map { |t| t["id"] }
    end

    # A task can carry its creative only in the trigger payload (creative_id is
    # nullable), and the permission check resolves that fallback. It has to stay
    # a check, not a bypass.
    test "omits an unlinked task whose payload creative is not readable" do
      task = build_task(linked: false)

      sign_in_as(@stranger, password: "password")

      assert_empty statuses_for(task.id)
    end

    test "resolves the payload creative for an unlinked task the user can read" do
      task = build_task(linked: false)

      sign_in_as(@owner, password: "password")

      assert_equal [task.id], statuses_for(task.id).map { |t| t["id"] }
    end

    test "ignores unparseable task ids instead of querying for them" do
      sign_in_as(@owner, password: "password")

      assert_empty statuses_for(%w[abc 0])
    end
  end
end
