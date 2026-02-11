# frozen_string_literal: true

require "test_helper"

class AdminOrchestrationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)  # system_admin in fixture
    @user = users(:two)   # non-admin
    sign_in_as(@admin, password: "password")
  end

  test "should get show as admin" do
    get collavre.admin_orchestration_path
    assert_response :success
    assert_select "h2", I18n.t("admin.orchestration.title")
    assert_select "textarea[name='policies_yaml']"
  end

  test "should return 404 for non-admin users" do
    delete collavre.session_path
    sign_in_as(@user, password: "password")
    get collavre.admin_orchestration_path
    assert_response :not_found
  end

  test "should redirect unauthenticated users" do
    delete collavre.session_path
    get collavre.admin_orchestration_path
    assert_response :redirect
  end

  test "should update policies with valid yaml" do
    valid_yaml = <<~YAML
      arbitration:
        global:
          strategy: primary_first
          max_responders: 1
      scheduling:
        global:
          max_concurrent_jobs: 3
          daily_token_limit: 50000
    YAML

    assert_changes -> { Collavre::OrchestratorPolicy.count }, from: 0, to: 2 do
      patch collavre.admin_orchestration_path, params: { policies_yaml: valid_yaml }
    end

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal I18n.t("admin.orchestration.updated"), flash[:notice]

    # Verify policies were created correctly
    arb_policy = Collavre::OrchestratorPolicy.find_by(policy_type: "arbitration")
    assert_equal "primary_first", arb_policy.config["strategy"]
    assert_equal 1, arb_policy.config["max_responders"]
    assert arb_policy.global?

    sched_policy = Collavre::OrchestratorPolicy.find_by(policy_type: "scheduling")
    assert_equal 3, sched_policy.config["max_concurrent_jobs"]
    assert_equal 50_000, sched_policy.config["daily_token_limit"]
  end

  test "should update policies with overrides" do
    valid_yaml = <<~YAML
      arbitration:
        global:
          strategy: all
        overrides:
          - scope_type: Topic
            scope_id: 123
            config:
              strategy: primary_first
              primary_agent_id: 456
            priority: 10
    YAML

    patch collavre.admin_orchestration_path, params: { policies_yaml: valid_yaml }

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal 2, Collavre::OrchestratorPolicy.count

    override = Collavre::OrchestratorPolicy.find_by(scope_type: "Topic")
    assert_equal 123, override.scope_id
    assert_equal "primary_first", override.config["strategy"]
    assert_equal 10, override.priority
  end

  test "should reject invalid yaml syntax" do
    invalid_yaml = "arbitration:\n  global: [invalid yaml"

    patch collavre.admin_orchestration_path, params: { policies_yaml: invalid_yaml }

    assert_response :unprocessable_entity
    assert_match(/syntax error/i, flash[:alert])
  end

  test "should reject unknown policy type" do
    invalid_yaml = <<~YAML
      unknown_type:
        global:
          strategy: all
    YAML

    patch collavre.admin_orchestration_path, params: { policies_yaml: invalid_yaml }

    assert_response :unprocessable_entity
    assert_includes flash[:alert], "unknown_type"
  end

  test "should reject invalid scope_type in overrides" do
    invalid_yaml = <<~YAML
      arbitration:
        overrides:
          - scope_type: InvalidScope
            scope_id: 1
            config:
              strategy: all
    YAML

    patch collavre.admin_orchestration_path, params: { policies_yaml: invalid_yaml }

    assert_response :unprocessable_entity
    assert_includes flash[:alert], "InvalidScope"
  end

  test "should reject invalid scope_id in overrides" do
    invalid_yaml = <<~YAML
      arbitration:
        overrides:
          - scope_type: Topic
            scope_id: -1
            config:
              strategy: all
    YAML

    patch collavre.admin_orchestration_path, params: { policies_yaml: invalid_yaml }

    assert_response :unprocessable_entity
    assert_includes flash[:alert], "scope_id"
  end

  test "should clear existing policies and replace with new ones" do
    # Create existing policy
    Collavre::OrchestratorPolicy.create!(
      policy_type: "arbitration",
      scope_type: nil,
      scope_id: nil,
      config: { "strategy" => "round_robin" },
      priority: 100,
      enabled: true
    )
    assert_equal 1, Collavre::OrchestratorPolicy.count

    # Update with different policy
    new_yaml = <<~YAML
      scheduling:
        global:
          max_concurrent_jobs: 10
    YAML

    patch collavre.admin_orchestration_path, params: { policies_yaml: new_yaml }

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal 1, Collavre::OrchestratorPolicy.count

    policy = Collavre::OrchestratorPolicy.first
    assert_equal "scheduling", policy.policy_type
    assert_equal 10, policy.config["max_concurrent_jobs"]
  end
end
