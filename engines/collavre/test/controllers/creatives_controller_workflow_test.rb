# frozen_string_literal: true

require "test_helper"
require_relative "../support/workflow_creative_helper"

class CreativesControllerWorkflowTest < ActionDispatch::IntegrationTest
  include WorkflowCreativeHelper

  setup do
    @original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user = users(:one)
    sign_in_as @user, password: "password"
    @workflow = create_workflow
    @rule = create_workflow_rule(parent: @workflow, sequence: 2)
    @payload = { "on" => "comment_created", "handler" => { "type" => "none" } }
  end

  teardown do
    ActiveJob::Base.queue_adapter = @original_adapter
  end

  test "lists active direct rules in tree order with raw payload and parser diagnostics" do
    first = create_workflow_rule(parent: @workflow, sequence: 1, event: "future_event")
    create_workflow_rule(parent: @workflow, archived_at: Time.current)
    create_workflow_rule(parent: @rule)
    create_workflow_creative(parent: @workflow, description: "Ordinary child")

    get workflow_path(@workflow), as: :json

    assert_response :success
    assert_equal [ first.id, @rule.id ], response.parsed_body.fetch("rules").map { |rule| rule.fetch("id") }
    invalid, valid = response.parsed_body.fetch("rules")
    assert_equal false, invalid.fetch("valid")
    assert invalid.fetch("errors").any?
    assert_equal true, valid.fetch("valid")
    assert_equal @rule.data.fetch("workflow_rule"), valid.fetch("rule")
    assert_equal @rule.description, valid.fetch("description")
    assert_equal Collavre::SystemEvents::Vocabulary.names, response.parsed_body.fetch("event_names")
    assert_equal Collavre::SystemEvents::Vocabulary.fetch("comment_created").sources,
                 response.parsed_body.fetch("sources_by_event").fetch("comment_created")
    assert_equal true, response.parsed_body.fetch("can_manage")
  end

  test "read permission permits inspection without management and hides denied children" do
    reader = users(:two)
    share(@workflow, reader, :read)
    share(@rule, reader, :no_access)
    sign_in_as reader, password: "password"

    get workflow_path(@workflow), as: :json

    assert_response :success
    assert_empty response.parsed_body.fetch("rules")
    assert_equal false, response.parsed_body.fetch("can_manage")
  end

  test "private workflow denies reads and unauthenticated requests require sign in" do
    private_workflow = create_workflow(user: users(:two))
    get workflow_path(private_workflow), as: :json
    assert_response :forbidden
    sign_out
    get workflow_path(@workflow), as: :json
    assert_redirected_to new_session_path
  end

  test "ordinary and archived creatives cannot be edited as workflows" do
    get workflow_path(@rule), as: :json
    assert_response :unprocessable_entity
    @workflow.update!(archived_at: Time.current)
    get workflow_path(@workflow), as: :json
    assert_response :unprocessable_entity
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :unprocessable_entity
  end

  test "canonical linked workflow reads and creates on origin" do
    linked = create_workflow_creative(description: "Link", origin: @workflow)
    get workflow_path(linked), as: :json
    assert_response :success
    assert_equal @workflow.id, response.parsed_body.fetch("workflow_id")
    post rule_path(linked), params: { description: "Created via link", workflow_rule: @payload }, as: :json
    assert_response :created
    assert_equal @workflow.id, Creative.find(response.parsed_body.fetch("id")).parent_id
  end

  test "foreign private linked placement does not expose a readable workflow origin" do
    linked = create_workflow_creative(description: "Private link", origin: @workflow, user: users(:two))
    get workflow_path(linked), as: :json
    assert_response :forbidden
    post rule_path(linked), params: { description: "No", workflow_rule: @payload }, as: :json
    assert_response :forbidden
  end

  test "management flags follow rule permission overrides" do
    admin = users(:two)
    share(@workflow, admin, :admin)
    share(@rule, admin, :read)
    sign_in_as admin, password: "password"

    get workflow_path(@workflow), as: :json

    assert_response :success
    assert_equal true, response.parsed_body.fetch("can_manage")
    assert_equal false, response.parsed_body.fetch("rules").sole.fetch("can_manage")
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :forbidden
  end

  test "management flags distinguish linked placement creation from origin rule updates" do
    linked = create_workflow_creative(description: "Shared link", origin: @workflow, user: users(:two))
    share(linked, @user, :read)

    get workflow_path(linked), as: :json

    assert_response :success
    assert_equal false, response.parsed_body.fetch("can_manage")
    assert_equal true, response.parsed_body.fetch("rules").sole.fetch("can_manage")
    post rule_path(linked), params: { description: "Denied", workflow_rule: @payload }, as: :json
    assert_response :forbidden
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :success
    assert_equal true, response.parsed_body.fetch("can_manage")
  end

  test "updates payload while preserving unrelated metadata and title" do
    @rule.update!(data: @rule.data.merge("custom" => { "keep" => true }))
    patch rule_path(@rule), params: { workflow_rule: @payload, description: "Ignored" }, as: :json
    assert_response :success
    assert_equal @payload, @rule.reload.data.fetch("workflow_rule")
    assert_equal({ "keep" => true }, @rule.data.fetch("custom"))
    assert_equal "workflow_rule", @rule.data.fetch("kind")
    assert_equal "Workflow rule", @rule.description
    assert_equal @payload, response.parsed_body.fetch("rule")
  end

  test "creates a titled direct workflow rule" do
    assert_difference -> { @workflow.children.count }, 1 do
      post rule_path(@workflow), params: { description: "Notify reviewer", workflow_rule: @payload }, as: :json
    end
    assert_response :created
    created = Creative.find(response.parsed_body.fetch("id"))
    assert_equal "Notify reviewer", created.description
    assert_equal @user, created.user
    assert created.workflow_rule?
    assert_equal @payload, created.data.fetch("workflow_rule")
    get workflow_path(@workflow), as: :json
    assert_includes response.parsed_body.fetch("rules").map { |rule| rule.fetch("id") }, created.id
  end

  test "created rules broadcast their initialized tree payload to collaborators" do
    @rule.update!(sequence: -1)
    reader = users(:two)
    share(@workflow, reader, :write)
    stream = "#{reader.to_gid_param}:creative_tree"

    messages = capture_broadcasts(stream) do
      perform_enqueued_jobs(only: Collavre::CreativeBroadcastJob) do
        post rule_path(@workflow), params: { description: "Broadcast rule", workflow_rule: @payload }, as: :json
      end
    end

    assert_response :created
    created = Creative.find(response.parsed_body.fetch("id"))
    payloads = messages.filter_map do |message|
      data = Nokogiri::HTML.fragment(message).at_css("turbo-stream[action='refresh_creative_tree']")&.[]("data")
      JSON.parse(data) if data
    end
    creations = payloads.select { |item| item.fetch("action") == "created" }
    assert_equal 1, creations.length
    payload = creations.sole.fetch("creative")
    assert_equal created.id, payload.fetch("id")
    assert_equal @workflow.id, payload.fetch("parent_id")
    assert_equal created.sequence, payload.fetch("sequence")
    assert_equal @rule.id, payload.fetch("previous_sibling_id")
    assert_equal "Broadcast rule", payload.fetch("inline_editor_payload").fetch("description_raw_html")
    assert_equal true, payload.fetch("can_write")
    assert_equal @payload, created.data.fetch("workflow_rule")
    assert Collavre::CreativeSharesCache.exists?(creative: created, user: reader)
  end

  test "updates and failed creates never enqueue a created broadcast" do
    clear_enqueued_jobs
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :success
    post rule_path(@workflow), params: { description: "Invalid", workflow_rule: {} }, as: :json
    assert_response :unprocessable_entity

    created_jobs = enqueued_jobs.select do |job|
      job[:job] == Collavre::CreativeBroadcastJob && job[:args][1] == "created"
    end
    assert_empty created_jobs
  end

  %i[en ko].each do |locale|
    test "invalid Liquid creates and updates return localized errors without mutations in #{locale}" do
      original = @rule.data.deep_dup
      [ "{% if", "{% if comment.content %}true", "comment.content ==" ].each do |expression|
        payload = @payload.merge("when" => { "liquid" => expression })
        headers = { "Accept-Language" => locale.to_s }
        patch rule_path(@rule), params: { workflow_rule: payload }, headers: headers, as: :json
        assert_response :unprocessable_entity
        expected = I18n.t("collavre.workflow.rule.errors.invalid_liquid", locale: locale)
        assert_equal [ expected ], response.parsed_body.fetch("errors")
        refute_match(/translation missing/i, expected)
        assert_equal original, @rule.reload.data

        assert_no_difference -> { Creative.count } do
          post rule_path(@workflow), params: { description: "Invalid Liquid", workflow_rule: payload },
               headers: headers, as: :json
        end
        assert_response :unprocessable_entity
        assert_equal [ expected ], response.parsed_body.fetch("errors")
      end
    end
  end

  test "valid Liquid shorthand and templates preserve advisory data on create and update" do
    [ "  comment.content contains 'deploy'  ", "  {% if comment.content %}true{% endif %}  " ].each do |expression|
      payload = @payload.merge("when" => { "liquid" => expression, "future_condition" => { "keep" => true } },
                               "emits" => "future_event")
      post rule_path(@workflow), params: { description: "Valid Liquid", workflow_rule: payload }, as: :json
      assert_response :created
      assert_equal payload, Creative.find(response.parsed_body.fetch("id")).data.fetch("workflow_rule")
      assert_equal 2, response.parsed_body.fetch("errors").length
      patch rule_path(@rule), params: { workflow_rule: payload }, as: :json
      assert_response :success
      assert_equal payload, @rule.reload.data.fetch("workflow_rule")
      assert_equal 2, response.parsed_body.fetch("errors").length
    end
  end

  test "editor reports malformed stored Liquid while preserving its raw input" do
    payload = @payload.merge("when" => { "liquid" => "{% if" })
    @rule.update!(data: @rule.data.merge("workflow_rule" => payload))

    get workflow_path(@workflow), as: :json

    assert_response :success
    rule = response.parsed_body.fetch("rules").sole
    assert_equal false, rule.fetch("valid")
    assert_equal [ I18n.t("collavre.workflow.rule.errors.invalid_liquid") ], rule.fetch("errors")
    assert_equal payload, rule.fetch("rule")
  end

  test "collaborator created rules retain workflow ownership and revocable access" do
    collaborator = users(:two)
    share(@workflow, collaborator, :admin)
    sign_in_as collaborator, password: "password"
    post rule_path(@workflow), params: { description: "Shared rule", workflow_rule: @payload }, as: :json
    assert_response :created
    created = Creative.find(response.parsed_body.fetch("id"))
    assert_equal @workflow.user_id, created.user_id
    assert_equal collaborator.id, Collavre::CreativeChangeSet.last.user_id

    sign_in_as @user, password: "password"
    get workflow_path(@workflow), as: :json
    assert_includes response.parsed_body.fetch("rules").map { |rule| rule.fetch("id") }, created.id
    patch rule_path(created), params: { workflow_rule: @payload }, as: :json
    assert_response :success

    perform_enqueued_jobs do
      CreativeShare.find_by!(creative: @workflow, user: collaborator).destroy!
    end
    sign_in_as collaborator, password: "password"
    patch rule_path(created), params: { workflow_rule: @payload }, as: :json
    assert_response :forbidden
    assert_not created.reload.has_permission?(collaborator, :read)
  end

  test "collaborator can immediately update a new rule while permission jobs are queued" do
    collaborator = users(:two)
    share(@workflow, collaborator, :admin)
    sign_in_as collaborator, password: "password"
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    post rule_path(@workflow), params: { description: "Queued permissions", workflow_rule: @payload }, as: :json
    assert_response :created
    assert_equal true, response.parsed_body.fetch("can_manage")
    created = Creative.find(response.parsed_body.fetch("id"))
    patch rule_path(created), params: { workflow_rule: @payload }, as: :json
    assert_response :success
    get workflow_path(@workflow), as: :json
    assert_includes response.parsed_body.fetch("rules").map { |rule| rule.fetch("id") }, created.id
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter if previous_adapter
  end

  test "updating workflow metadata does not leave an empty history change set" do
    assert_no_difference -> { Collavre::CreativeChangeSet.count } do
      patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    end

    assert_response :success
    assert_equal @payload, @rule.reload.data.fetch("workflow_rule")
    assert_empty Collavre::CreativeChange.where(creative_id: @rule.id)
  end

  test "rule creation records editor history with the requested viewing context" do
    post rule_path(@workflow), params: {
      description: "Recorded rule", workflow_rule: @payload,
      history_anchor_id: @workflow.id, change_group_token: "workflow-create-session"
    }, as: :json

    assert_response :created
    created_id = response.parsed_body.fetch("id")
    change_set = Collavre::CreativeChangeSet.sole
    assert_equal @workflow.id, change_set.anchor_creative_id
    assert_equal "view_root", change_set.anchor_source
    assert_equal "editor", change_set.origin
    assert_equal @user.id, change_set.user_id
    assert_equal "workflow-create-session", change_set.change_group_token
    change = change_set.creative_changes.sole
    assert_equal created_id, change.creative_id
    assert_equal "create", change.operation
    assert_equal "Recorded rule", change.after.fetch("description")
    assert_equal @workflow.id, change.after.fetch("parent_id")
  end

  test "advisory diagnostics allow save and remain visible" do
    @payload["when"] = { "future_condition" => "keep" }
    @payload["emits"] = "future_event"
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :success
    assert_equal true, response.parsed_body.fetch("valid")
    assert_equal 2, response.parsed_body.fetch("errors").length
    assert_equal @payload, @rule.reload.data.fetch("workflow_rule")
  end

  test "fatal and malformed payloads fail without mutations or creations" do
    invalid = [ nil, [], "{}", true, { "on" => "unknown", "handler" => { "type" => "none" } },
                @payload.merge("when" => { "source" => "cron" }),
                @payload.merge("handler" => { "type" => "agent", "agent_ids" => [ "1" ] }) ]
    original = @rule.data.deep_dup
    invalid.each do |payload|
      patch rule_path(@rule), params: { workflow_rule: payload }, as: :json
      assert_response :unprocessable_entity
      assert response.parsed_body.fetch("errors").any?
      assert_equal original, @rule.reload.data
      assert_no_difference -> { Creative.count } do
        post rule_path(@workflow), params: { description: "Invalid", workflow_rule: payload }, as: :json
      end
      assert_response :unprocessable_entity
    end
  end

  test "model validation failure preserves the stored rule and returns actionable errors" do
    # Simulate an imported legacy row that no longer satisfies model validation.
    @rule.update_column(:description, "")
    original = @rule.reload.data.deep_dup
    assert_not @rule.valid?
    expected_errors = @rule.errors.full_messages

    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json

    assert_response :unprocessable_entity
    assert_equal expected_errors, response.parsed_body.fetch("errors")
    assert_equal original, @rule.reload.data
    assert_equal "", @rule.description
  end

  test "new rules require a title" do
    assert_no_difference -> { Creative.count } do
      post rule_path(@workflow), params: { description: " ", workflow_rule: @payload }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "write permission cannot update or create rules" do
    writer = users(:two)
    share(@workflow, writer, :write)
    sign_in_as writer, password: "password"
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :forbidden
    post rule_path(@workflow), params: { description: "Denied", workflow_rule: @payload }, as: :json
    assert_response :forbidden
  end

  test "rule admin cannot update without admin permission on its workflow" do
    rule_admin = users(:two)
    share(@workflow, rule_admin, :write)
    share(@rule, rule_admin, :admin)
    original = @rule.data.deep_dup
    sign_in_as rule_admin, password: "password"

    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json

    assert_response :forbidden
    assert_equal original, @rule.reload.data
  end

  test "workflow admin cannot update a separately denied rule" do
    admin = users(:two)
    share(@workflow, admin, :admin)
    share(@rule, admin, :no_access)
    sign_in_as admin, password: "password"
    patch rule_path(@rule), params: { workflow_rule: @payload }, as: :json
    assert_response :forbidden
  end

  test "nested archived and linked rules cannot be updated through workflow API" do
    nested = create_workflow_rule(parent: @rule)
    archived = create_workflow_rule(parent: @workflow, archived_at: Time.current)
    linked = create_workflow_creative(description: "Rule link", parent: @workflow, origin: @rule)
    [ nested, archived, linked ].each do |creative|
      patch rule_path(creative), params: { workflow_rule: @payload }, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "linked child with its own rule metadata edits the direct row without mutating origin" do
    linked = create_workflow_rule(parent: @workflow, origin: @rule)
    original = @rule.data.deep_dup
    get workflow_path(@workflow), as: :json
    assert_response :success
    assert_includes response.parsed_body.fetch("rules").map { |rule| rule.fetch("id") }, linked.id

    patch rule_path(linked), params: { workflow_rule: @payload }, as: :json
    assert_response :success
    assert_equal @payload, linked.reload.data.fetch("workflow_rule")
    assert_equal original, @rule.reload.data
  end

  test "agent options contain only visible agents with feedback permission warnings" do
    visible = users(:ai_bot)
    visible.update!(created_by_id: @user.id)
    private_agent = users(:three)
    private_agent.update!(llm_vendor: "google", searchable: false, name: "Private agent secret")
    @rule.update!(data: @rule.data.merge("workflow_rule" => {
      "on" => "comment_created", "handler" => { "type" => "agent", "agent_ids" => [ visible.id, private_agent.id ] }
    }))

    get workflow_path(@workflow), as: :json
    assert_response :success
    agents = response.parsed_body.fetch("agents")
    assert_equal [ visible.id ], agents.map { |agent| agent.fetch("id") }
    assert_equal false, agents.first.fetch("can_respond_here")
    assert agents.first.fetch("warnings").any?
    assert response.parsed_body.fetch("rules").first.fetch("warnings").any?
    assert_not_includes response.body, "Private agent secret"
    assert response.parsed_body.fetch("permission_note").present?

    share(@workflow, visible, :feedback)
    get workflow_path(@workflow), as: :json
    assert_equal true, response.parsed_body.fetch("agents").first.fetch("can_respond_here")
    assert_empty response.parsed_body.fetch("agents").first.fetch("warnings")
  end

  test "private agents shared on workflow are selectable without exposing unrelated private agents" do
    agent = users(:ai_bot)
    share(@workflow, agent, :feedback)
    get workflow_path(@workflow), as: :json
    assert_response :success
    assert_includes response.parsed_body.fetch("agents").map { |option| option.fetch("id") }, agent.id
  end

  test "workflow errors are localized in Korean" do
    get workflow_path(@rule), headers: { "Accept-Language" => "ko" }, as: :json
    assert_response :unprocessable_entity
    assert_equal I18n.t("collavre.workflow.editor.errors.not_workflow", locale: :ko), response.parsed_body.fetch("error")
    assert_match(/[가-힣]/, response.parsed_body.fetch("error"))
  end

  private

  def workflow_path(creative)
    "/creatives/#{creative.id}/workflow"
  end

  def rule_path(creative)
    "/creatives/#{creative.id}/workflow_rule"
  end

  def share(creative, user, permission)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: user, permission: permission)
    end
  end
end
