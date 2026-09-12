# frozen_string_literal: true

require_relative "../application_system_test_case"
require_relative "../support/workflow_creative_helper"

class WorkflowRuleEditorTest < ApplicationSystemTestCase
  include WorkflowCreativeHelper

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current, locale: "en")
    @workflow = create_workflow
    @agent = users(:ai_bot)
    @agent.update!(created_by_id: @user.id)
    sign_in_via_ui(@user, password: "password")
  end

  test "create rule save controls and reload stored values" do
    visit collavre.creatives_path(id: @workflow.id)
    assert_docked_comments_loaded
    click_link label(:title)
    assert_button label(:add_rule), disabled: false
    assert_current_path collavre.edit_creative_path(@workflow)
    click_button label(:add_rule)
    fill_in label(:rule_title), with: "Review comments"
    choose label("handlers.agent")
    select @agent.name, from: label(:agents)
    assert_text label(:agent_cannot_respond_here)
    assert_equal "inline-flex", page.evaluate_script("getComputedStyle(document.querySelector('.workflow-choice')).display")
    check label("source_labels.cron")
    select label(:yes), from: label(:author)
    fill_in label(:phrase), with: "review"
    find("input[name='phrase']").send_keys(:enter)
    assert_button "review ×"
    find("summary", text: label(:advanced)).click
    fill_in label(:liquid), with: "comment.content != blank"
    click_button label(:save)
    assert_text label(:saved)
    assert_no_selector "input[name=title]", visible: true
    visit current_url
    assert_selector ".workflow-rule h3", text: "Review comments"
    assert_checked_field label("handlers.agent")
    assert_select label(:agents), selected: [ @agent.name ]
    assert_checked_field label("source_labels.cron")
    assert_select label(:author), selected: label(:yes)
    assert_button "review ×"
    find("summary", text: label(:advanced)).click
    assert_field label(:liquid), with: "comment.content != blank"
    page.execute_script("window.scrollTo(0, 0)")
    page.save_screenshot(Rails.root.join("tmp/workflow-editor-desktop.png"))
    resize_window_to(390, 844)
    page.execute_script("window.scrollTo(0, 0)")
    page.save_screenshot(Rails.root.join("tmp/workflow-editor-mobile.png"))
    assert_equal [ "review" ], @workflow.children.sole.data.dig("workflow_rule", "when", "body_contains")
  end

  test "server rejects missing agents and retains input for repair" do
    visit collavre.edit_creative_path(@workflow)
    click_button label(:add_rule)
    fill_in label(:rule_title), with: "Keep this title"
    choose label("handlers.agent")
    click_button label(:save)
    assert_text I18n.t("collavre.workflow.rule.errors.no_agent")
    assert_field label(:rule_title), with: "Keep this title"
    choose label("handlers.none")
    click_button label(:save)
    assert_text label(:saved)
    assert_equal "Keep this title", @workflow.children.sole.description
  end

  test "readers can inspect but cannot edit rules and ordinary creatives have no panel" do
    foreign = create_workflow(user: users(:two))
    create_workflow_rule(parent: foreign, user: users(:two))
    perform_enqueued_jobs do
      CreativeShare.create!(creative: foreign, user: @user, permission: :read)
    end
    visit collavre.edit_creative_path(foreign)
    assert_text label(:read_only)
    assert_button label(:save), disabled: true
    assert_button label(:add_rule), disabled: true
    ordinary = create_workflow_creative(description: "Ordinary")
    visit collavre.edit_creative_path(ordinary)
    assert_no_selector ".workflow-editor"
  end

  private

  def label(key)
    I18n.t("collavre.workflow.editor.#{key}")
  end
end
