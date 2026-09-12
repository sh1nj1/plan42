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
    perform_enqueued_jobs do
      CreativeShare.create!(creative: @workflow, user: users(:two), permission: :read)
    end
    sign_in_as users(:two), password: "password"
    get edit_creative_path(@workflow)
    assert_response :success
    assert_select "[data-controller='creatives--workflow-rule']"
    get edit_creative_path(@workflow), params: { inline: true }
    assert_response :redirect
    ordinary = create_workflow_creative(description: "Ordinary")
    get edit_creative_path(ordinary)
    assert_response :redirect
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

  test "foreign private placement does not expose workflow editor" do
    linked = create_workflow_creative(description: "Secret placement", origin: @workflow, user: users(:two))
    get edit_creative_path(linked)
    assert_response :forbidden
    assert_select "[data-controller='creatives--workflow-rule']", count: 0
  end
end
