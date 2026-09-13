# frozen_string_literal: true

require_relative "../application_system_test_case"
require_relative "../support/workflow_creative_helper"

class CreativeTypeEditorTest < ApplicationSystemTestCase
  include WorkflowCreativeHelper

  setup do
    @user = users(:one)
    @user.update!(locale: "en", email_verified_at: Time.current)
    @creative = create_workflow_creative(description: "Type selector test")
    resize_window_to
    sign_in_via_ui(@user, password: "password")
  end

  test "search select workflow save body reopen and access rules" do
    open_editor
    field = find(".lexical-content-editable")
    field.set("Edited body and type")
    fill_in "inline-creative-type", with: "Work"
    find("#inline-creative-type").send_keys(:enter)
    assert_field "inline-creative-type", with: "Workflow"
    find("#inline-close").click
    assert_no_selector "#inline-edit-form", visible: true
    assert @creative.reload.workflow?
    assert_includes @creative.effective_description, "Edited body and type"
    open_editor
    assert_field "inline-creative-type", with: "Workflow"
    click_link "Edit rules"
    assert_current_path collavre.edit_creative_path(@creative)
    assert_button I18n.t("collavre.workflow.editor.add_rule")
  end

  test "custom addition cancellation and reload" do
    open_editor
    fill_in "inline-creative-type", with: "Project Plan"
    find("#inline-creative-type").send_keys(:escape)
    assert_field "inline-creative-type", with: "General"
    assert_equal "", @creative.reload.creative_type
    fill_in "inline-creative-type", with: "Project Plan"
    find("[role=option]", text: 'Add type "project plan"').click
    assert_field "inline-creative-type", with: "project plan"
    click_button "Cancel type change"
    assert_field "inline-creative-type", with: "General"
    fill_in "inline-creative-type", with: "Project Plan"
    find("#inline-creative-type").send_keys(:enter)
    find("#inline-close").click
    assert_no_selector "#inline-edit-form", visible: true
    assert_equal "project plan", @creative.reload.creative_type
    open_editor
    assert_field "inline-creative-type", with: "project plan"
    fill_in "inline-creative-type", with: "project"
    assert_selector "[role=option]", text: "project plan"
    assert_no_selector "[role=option]", text: 'Add type "project plan"'
    page.save_screenshot(Rails.root.join("tmp/creative-type-desktop.png"))
    resize_window_to(390, 844)
    page.save_screenshot(Rails.root.join("tmp/creative-type-mobile.png"))
  end

  test "rejected reverse conversion retains body and type until repaired" do
    @creative.update!(data: { "kind" => "workflow", "workflow" => { "mode" => "shadow" } })
    open_editor
    find(".lexical-content-editable").set("Keep this draft")
    fill_in "inline-creative-type", with: "General"
    find("#inline-creative-type").send_keys(:enter)
    find("#inline-close").click
    assert_selector "[role=alert]", text: I18n.t("collavre.creatives.types.errors.data_present")
    assert_selector ".lexical-content-editable", text: "Keep this draft"
    assert_field "inline-creative-type", with: "General"
    assert @creative.reload.workflow?
    click_button "Cancel type change"
    find("#inline-close").click
    assert_no_selector "#inline-edit-form", visible: true
    assert_includes @creative.reload.effective_description, "Keep this draft"
  end

  test "Korean labels and reserved inbox control" do
    @user.update!(locale: "ko")
    @creative.update!(data: { "kind" => "inbox" })
    open_editor
    assert_field "타입", disabled: true, with: "인박스"
    assert_button "타입 변경 취소", disabled: true
  end

  private

  def open_editor
    visit collavre.creatives_path
    row = find("#creative-#{@creative.id}")
    row.hover
    row.find(".edit-inline-btn").click
    assert_selector "[data-editor-ready=true] .lexical-content-editable:focus"
  end
end
