# frozen_string_literal: true

require "test_helper"

class CreativeContextsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    sign_in_as(@admin, password: "password")

    Collavre::Current.user = @admin
    @project = Collavre::Creative.create!(description: "Project", user: @admin)
    @development = Collavre::Creative.create!(description: "Development", user: @admin, parent: @project)
    @features = Collavre::Creative.create!(description: "Features", user: @admin, parent: @project)
    @feature_a = Collavre::Creative.create!(description: "Feature A", user: @admin, parent: @features)
  end

  test "GET contexts returns empty list when no contexts configured" do
    get contexts_creative_path(@feature_a), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [], json["contexts"]
    assert json["can_manage"]
  end

  test "GET contexts returns own and inherited contexts" do
    @features.update!(data: { "context_ids" => [ @development.id ] })

    get contexts_creative_path(@feature_a), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    contexts = json["contexts"]
    assert_equal 1, contexts.length

    ctx = contexts.first
    assert_equal @development.id, ctx["id"]
    assert ctx["inherited"]
  end

  test "PATCH update_contexts sets context_ids" do
    patch update_contexts_creative_path(@features), params: {
      context_ids: [ @development.id ]
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :success
    @features.reload
    assert_equal [ @development.id ], @features.data["context_ids"]
  end

  test "PATCH update_contexts sets disabled_context_ids" do
    @features.update!(data: { "context_ids" => [ @development.id ] })

    patch update_contexts_creative_path(@features), params: {
      disabled_context_ids: [ @development.id ]
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :success
    @features.reload
    assert_equal [ @development.id ], @features.data["disabled_context_ids"]
  end

  test "PATCH update_contexts cleans up empty disabled_context_ids" do
    @features.update!(data: { "context_ids" => [ @development.id ], "disabled_context_ids" => [ @development.id ] })

    patch update_contexts_creative_path(@features), params: {
      disabled_context_ids: []
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :success
    @features.reload
    refute @features.data.key?("disabled_context_ids")
  end

  test "PATCH update_contexts sets disabled_self_context" do
    patch update_contexts_creative_path(@features), params: {
      disabled_self_context: true
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :success
    @features.reload
    assert_equal true, @features.data["disabled_self_context"]
  end

  test "PATCH update_contexts clears disabled_self_context when false" do
    @features.update!(data: { "disabled_self_context" => true })

    patch update_contexts_creative_path(@features), params: {
      disabled_self_context: false
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :success
    @features.reload
    refute @features.data.key?("disabled_self_context")
  end

  test "GET contexts returns disabled_self_context flag" do
    @features.update!(data: { "disabled_self_context" => true })

    get contexts_creative_path(@features), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["disabled_self_context"]
  end

  test "GET contexts excludes self from context list to prevent duplicates" do
    # Parent has feature_a as context → feature_a should not see itself in contexts list
    @features.update!(data: { "context_ids" => [ @feature_a.id, @development.id ] })

    get contexts_creative_path(@feature_a), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    context_ids = json["contexts"].map { |c| c["id"] }
    refute_includes context_ids, @feature_a.id, "Self creative should be excluded from contexts"
    assert_includes context_ids, @development.id, "Other contexts should still be present"
  end

  test "GET contexts inherits disabled state from parent" do
    @features.update!(data: { "context_ids" => [ @development.id ], "disabled_context_ids" => [ @development.id ] })

    get contexts_creative_path(@feature_a), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    ctx = json["contexts"].find { |c| c["id"] == @development.id }
    assert ctx, "Development context should appear in child"
    assert ctx["disabled"], "Disabled state from parent should be inherited by child"
  end

  test "PATCH update_contexts filters out parent-inherited disabled IDs to prevent sticky disablement" do
    @features.update!(data: { "context_ids" => [ @development.id ], "disabled_context_ids" => [ @development.id ] })

    # Client sends ALL disabled IDs (including inherited ones) from the child
    patch update_contexts_creative_path(@feature_a), params: {
      disabled_context_ids: [ @development.id ]
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :success
    @feature_a.reload
    # Inherited disabled ID should NOT be stored on the child
    refute @feature_a.data&.key?("disabled_context_ids"),
      "Inherited disabled IDs should be filtered out, not copied to child"
  end

  test "PATCH update_contexts requires admin permission" do
    regular_user = users(:two)
    sign_in_as(regular_user, password: "password")

    patch update_contexts_creative_path(@features), params: {
      context_ids: [ @development.id ]
    }, headers: { "ACCEPT" => "application/json" }, as: :json

    assert_response :forbidden
  end
end
