# frozen_string_literal: true

require "test_helper"
require_relative "../support/workflow_creative_helper"

class CreativesControllerWorkflowPanelTest < ActionDispatch::IntegrationTest
  include WorkflowCreativeHelper

  setup do
    @workflow = create_workflow
    sign_in_as users(:one), password: "password"
  end

  test "active workflow edit renders localized controls and tree navigation" do
    get edit_creative_path(@workflow)
    assert_response :success
    assert_select "[data-controller='creatives--workflow-rule']"
    assert_select "template [name='event']"
    assert_select "template input[type='radio'][value='agent']"
    assert_select "template select[multiple]"
    assert_select "template details:not([open]) textarea[name='expression']"
    assert_select "a[href='#{creative_path(@workflow)}']", text: I18n.t("collavre.workflow.editor.tree_link")
    users(:one).update!(locale: "ko")
    get edit_creative_path(@workflow), headers: { "Accept-Language" => "ko" }
    assert_select "h2", text: I18n.t("collavre.workflow.editor.title", locale: :ko)
  end

  test "workflow tree provides a reachable editor link including effective origin" do
    linked = create_workflow_creative(description: "Link", origin: @workflow)
    [ @workflow, linked ].each do |creative|
      get creatives_path(id: creative.id)
      assert_response :success
      assert_select "a[href='#{edit_creative_path(creative)}'][data-turbo-frame='_top']"
      get edit_creative_path(creative)
      assert_response :success
      assert_select "[data-controller='creatives--workflow-rule']"
    end
  end

  test "readers can view workflow panel but ordinary edit still requires write" do
    ordinary = create_workflow_creative(description: "Ordinary")
    rule = create_workflow_rule(parent: @workflow)
    archived = create_workflow(archived_at: Time.current)
    perform_enqueued_jobs do
      [ @workflow, ordinary, archived ].each do |creative|
        CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
      end
    end
    sign_in_as users(:two), password: "password"
    get edit_creative_path(@workflow)
    assert_response :success
    assert_select "[data-controller='creatives--workflow-rule']"
    get edit_creative_path(@workflow), params: { inline: true }
    assert_edit_denied(@workflow)
    [ ordinary, rule, archived ].each { |creative| assert_edit_requests_denied(creative) }
  end

  test "writers can open ordinary and inline editors" do
    ordinary = create_workflow_creative(description: "Ordinary")
    perform_enqueued_jobs do
      [ @workflow, ordinary ].each do |creative|
        CreativeShare.create!(creative: creative, user: users(:two), permission: :write)
      end
    end
    sign_in_as users(:two), password: "password"

    [ @workflow, ordinary ].each do |creative|
      get edit_creative_path(creative)
      assert_response :success
      get edit_creative_path(creative), params: { inline: true }
      assert_response :success
      assert_select "form"
    end
  end

  test "ordinary archived and linked archived workflows have no panel" do
    ordinary = create_workflow_creative(description: "Ordinary")
    linked = create_workflow_creative(description: "Link", origin: @workflow)
    @workflow.update!(archived_at: Time.current)
    [ ordinary, @workflow, linked ].each do |creative|
      get edit_creative_path(creative)
      assert_response :success
      assert_select "[data-controller='creatives--workflow-rule']", count: 0
    end
  end

  test "private creatives deny edit uniformly regardless of kind or archive state" do
    edit_creatives(user: users(:two)).each { |creative| assert_edit_requests_denied(creative) }
  end

  test "foreign private placements deny edit even when their origins are writable" do
    edit_creatives(user: users(:one)).each do |origin|
      linked = create_workflow_creative(description: "Secret placement", origin: origin, user: users(:two))
      assert_edit_requests_denied(linked)
    end
  end

  test "readers can open workflow editor through a shared placement" do
    linked = create_workflow_creative(description: "Shared placement", origin: @workflow)
    perform_enqueued_jobs do
      [ @workflow, linked ].each do |creative|
        CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
      end
    end
    sign_in_as users(:two), password: "password"

    get edit_creative_path(linked)
    assert_response :success
    assert_select "[data-controller='creatives--workflow-rule']"
    get edit_creative_path(linked), params: { inline: true }
    assert_edit_denied(linked)
  end

  private

  def edit_creatives(user:)
    workflow = create_workflow(user: user)
    [
      create_workflow_creative(description: "Ordinary", user: user),
      workflow,
      create_workflow_rule(parent: workflow, user: user),
      create_workflow(user: user, archived_at: Time.current)
    ]
  end

  def assert_edit_requests_denied(creative)
    [ :html, :json ].product([ false, true ]).each do |format, inline|
      get edit_creative_path(creative), params: inline ? { inline: true } : {}, as: format
      assert_edit_denied(creative)
    end
  end

  def assert_edit_denied(creative)
    assert_redirected_to creative_path(creative)
    assert_equal I18n.t("collavre.creatives.errors.no_permission"), flash[:alert]
    assert_not_includes response.body, "creatives--workflow-rule"
    assert_not_includes response.body, creative.description
  end
end
