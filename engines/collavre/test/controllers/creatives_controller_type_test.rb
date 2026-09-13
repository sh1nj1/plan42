# frozen_string_literal: true

require "test_helper"
require_relative "../support/workflow_creative_helper"

class CreativesControllerTypeTest < ActionDispatch::IntegrationTest
  include WorkflowCreativeHelper

  setup do
    @user = users(:one)
    sign_in_as @user, password: "password"
    @creative = create_workflow_creative(description: "Original")
  end

  test "saves body and workflow together without publishing an event and opens rule editor" do
    assert_no_difference "Collavre::Workflow::Execution.count" do
      change_type("workflow")
    end
    assert_response :success
    assert_equal "workflow", response.parsed_body["creative_type"]
    assert @creative.reload.workflow?
    assert_equal "Edited", @creative.description
    get edit_creative_path(@creative)
    assert_response :success
    assert_select "[data-controller='creatives--workflow-rule']"
    get creative_path(@creative), as: :json
    assert_equal "workflow", response.parsed_body["creative_type"]
  end

  test "normalizes custom classifications and removes kind for general" do
    change_type("  ＰＲＯＪＥＣＴ   Plan  ")
    assert_response :success
    assert_equal "project plan", @creative.reload.creative_type
    change_type("PROJECT PLAN")
    assert_response :success
    assert_equal "project plan", @creative.reload.creative_type
    change_type("")
    assert_response :success
    assert_not @creative.reload.data.key?("kind")
  end

  test "maximum length and whitespace general are accepted" do
    change_type("가" * 64)
    assert_response :success
    change_type("   ")
    assert_response :success
    assert_equal "", @creative.reload.creative_type
  end

  test "invalid inputs reject body and type atomically in both languages" do
    [ "en", "ko" ].each do |locale|
      @user.update!(locale: locale)
      [ nil, [], {}, 4, "x" * 65, "bad\u0000type", "bad\ntype" ].each do |value|
        patch creative_path(@creative), params: { creative: { description: "Rejected", creative_type: value } }, headers: { "Accept-Language" => locale }, as: :json
        assert_response :unprocessable_entity
        assert_equal "Original", @creative.reload.description
        assert_equal "", @creative.creative_type
        assert_equal [ I18n.t("collavre.creatives.types.errors.invalid", locale: locale) ], response.parsed_body["errors"]
      end
    end
  end

  test "system discriminators cannot be entered including normalized spellings" do
    %w[inbox INBOX workflow_rule ＷＯＲＫＦＬＯＷ＿ＲＵＬＥ].each do |value|
      change_type(value)
      assert_response :unprocessable_entity
      assert_equal "Original", @creative.reload.description
    end
  end

  test "system discriminators cannot be left but unchanged body updates work" do
    %w[inbox workflow_rule].each do |value|
      @creative.update!(data: { "kind" => value })
      change_type("")
      assert_response :unprocessable_entity
      assert_equal value, @creative.reload.creative_type
      change_type(value)
      assert_response :success
      assert_equal "Edited", @creative.reload.description
    end
  end

  test "workflow settings including empty values prevent activation or deactivation" do
    [ "workflow", "workflow_rule" ].each do |key|
      [ nil, {}, { "mode" => "on" } ].each do |config|
        [ "", "workflow" ].each do |current|
          @creative.update!(data: { "kind" => current, key => config })
          before = @creative.data.deep_dup
          change_type(current.empty? ? "workflow" : "")
          assert_response :unprocessable_entity
          assert_equal before, @creative.reload.data
        end
      end
    end
  end

  test "direct rules including archived ones block reverse conversion without deleting data" do
    @creative.update!(data: { "kind" => "workflow" })
    rule = create_workflow_rule(parent: @creative, archived_at: Time.current)
    change_type("project")
    assert_response :unprocessable_entity
    assert @creative.reload.workflow?
    assert rule.reload.workflow_rule?
  end

  test "empty workflows may convert back and ordinary children are retained" do
    @creative.update!(data: { "kind" => "workflow" })
    child = create_workflow_creative(description: "Child", parent: @creative)
    change_type("")
    assert_response :success
    assert_equal @creative.id, child.reload.parent_id
  end

  test "writer can classify but cannot activate or deactivate workflow" do
    share(@creative, users(:two), :write)
    sign_in_as users(:two), password: "password"
    change_type("project")
    assert_response :success
    change_type("workflow")
    assert_response :unprocessable_entity
    @creative.reload.update!(data: { "kind" => "workflow" })
    change_type("")
    assert_response :unprocessable_entity
  end

  test "reader and anonymous cannot change body or type" do
    share(@creative, users(:two), :read)
    sign_in_as users(:two), password: "password"
    change_type("project")
    assert_response :forbidden
    assert_equal "Original", @creative.reload.description
    sign_out
    change_type("project")
    assert_redirected_to new_session_path
  end

  test "linked writes update origin and rejected requests roll back placement too" do
    linked = create_workflow_creative(description: "Link", origin: @creative)
    patch creative_path(linked), params: { creative: { creative_type: "workflow", description: "Linked edit" } }, as: :json
    assert_response :success
    assert @creative.reload.workflow?
    assert_equal "Linked edit", @creative.description
    parent = create_workflow_creative(description: "Parent")
    patch creative_path(linked), params: { creative: { parent_id: parent.id, creative_type: "inbox", description: "Rejected" } }, as: :json
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any?
    assert_nil linked.reload.parent_id
    assert_equal "Linked edit", @creative.reload.description
  end

  test "private linked placement cannot edit a readable origin" do
    linked = create_workflow_creative(description: "Link", origin: @creative, user: users(:two))
    patch creative_path(linked), params: { creative: { creative_type: "workflow" } }, as: :json
    assert_response :forbidden
    assert_not @creative.reload.workflow?
  end

  test "archived and externally managed types cannot change" do
    @creative.update!(archived_at: Time.current)
    change_type("project")
    assert_response :unprocessable_entity
    @creative.update!(archived_at: nil, data: { "source" => { "type" => "type-test" } })
    Creative.register_read_only_source("type-test")
    patch creative_path(@creative), params: { creative: { creative_type: "project" } }, as: :json
    assert_response :unprocessable_entity
  ensure
    Creative.read_only_source_types.delete("type-test")
  end

  test "creates general custom and workflow types while refusing system types" do
    [ "", "project", "workflow" ].each do |value|
      post creatives_path, params: { creative: { description: "New", creative_type: value } }, as: :json
      assert_response :success
      assert_equal value, Creative.find(response.parsed_body["id"]).creative_type
    end
    post creatives_path, params: { creative: { description: "New", creative_type: "inbox" } }, as: :json
    assert_response :unprocessable_entity
  end

  test "new child workflow requires parent admin and cannot bypass direct rule contract" do
    share(@creative, users(:two), :write)
    sign_in_as users(:two), password: "password"
    %w[workflow workflow_rule].each do |value|
      post creatives_path, params: { creative: { parent_id: @creative.id, description: "New", creative_type: value } }, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "metadata still cannot overwrite kind" do
    @creative.update!(data: { "kind" => "workflow" })
    patch update_metadata_creative_path(@creative), params: { data: { kind: "inbox" }.to_json }, as: :json
    assert_response :success
    assert @creative.reload.workflow?
  end

  test "stale body and metadata requests preserve a newly committed type" do
    [ :body, :metadata ].each do |request|
      @creative.update!(data: {})
      stale = Creative.find(@creative.id)
      Creative.where(id: @creative.id).update_all(data: { "kind" => "workflow" })
      Creative.stub(:find, stale) do
        if request == :body
          patch creative_path(@creative), params: { creative: { description: "New body", content_type_input: "markdown", markdown_source: "New body" } }, as: :json
        else
          patch update_metadata_creative_path(@creative), params: { data: { label: "New metadata" }.to_json }, as: :json
        end
      end
      assert_response :success
      assert @creative.reload.workflow?, "#{request} must preserve the committed type"
    end
  end

  private

  def share(creative, user, permission)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: user, permission: permission)
    end
  end

  def change_type(value)
    patch creative_path(@creative), params: { creative: { description: "Edited", creative_type: value } }, as: :json
  end
end
