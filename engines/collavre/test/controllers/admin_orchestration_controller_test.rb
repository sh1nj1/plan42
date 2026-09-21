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

  test "should accept collaboration policy type" do
    valid_yaml = <<~YAML
      collaboration:
        global:
          a2a_completion_instruction: "- When done, report results to the requester via @name: mention"
          mention_rule: "- Call other agents: @name: request"
    YAML

    assert_changes -> { Collavre::OrchestratorPolicy.count }, from: 0, to: 1 do
      patch admin_orchestration_path, params: { policies_yaml: valid_yaml }
    end

    assert_redirected_to admin_orchestration_path

    policy = Collavre::OrchestratorPolicy.find_by(policy_type: "collaboration")
    assert policy.global?
    assert_equal "- When done, report results to the requester via @name: mention",
                 policy.config["a2a_completion_instruction"]
    assert_equal "- Call other agents: @name: request",
                 policy.config["mention_rule"]
  end

  test "should save and load collaboration alongside other policies" do
    valid_yaml = <<~YAML
      arbitration:
        global:
          strategy: all
      collaboration:
        global:
          a2a_completion_instruction: "- Custom completion"
    YAML

    patch admin_orchestration_path, params: { policies_yaml: valid_yaml }

    assert_redirected_to admin_orchestration_path
    assert_equal 2, Collavre::OrchestratorPolicy.count

    collab = Collavre::OrchestratorPolicy.find_by(policy_type: "collaboration")
    assert_equal "- Custom completion", collab.config["a2a_completion_instruction"]
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

  %w[global override].each do |scope|
    %w[on off].each do |value|
      test "rejects unquoted #{value} with a symbol key in #{scope}" do
        existing = Collavre::OrchestratorPolicy.create!(
          policy_type: "arbitration", config: { "strategy" => "all" }
        )
        original_attributes = existing.attributes

        assert_no_difference "Collavre::OrchestratorPolicy.count" do
          patch collavre.admin_orchestration_path, params: {
            policies_yaml: matching_yaml(scope, ":workflow_routing: #{value}")
          }
        end

        assert_response :unprocessable_entity
        assert_equal I18n.t("admin.orchestration.invalid_workflow_routing"), flash[:alert]
        assert_equal original_attributes, existing.reload.attributes
      end
    end

    %w[off shadow on].each do |mode|
      test "accepts quoted #{mode} with a symbol key in #{scope}" do
        patch collavre.admin_orchestration_path, params: {
          policies_yaml: matching_yaml(scope, ":workflow_routing: '#{mode}'")
        }

        assert_redirected_to collavre.admin_orchestration_path
        policy = Collavre::OrchestratorPolicy.find_by!(policy_type: "matching")
        assert_equal({ "workflow_routing" => mode }, policy.config)
        assert_equal scope == "global", policy.global?
      end
    end

    %w[on off true false null 1 invalid :on [] {}].each do |value|
      test "rejects #{value} workflow routing in #{scope} without replacing existing policies" do
        existing = Collavre::OrchestratorPolicy.create!(
          policy_type: "arbitration", config: { "strategy" => "all" }
        )
        original_attributes = existing.attributes
        yaml = matching_yaml(scope, "workflow_routing: #{value}")

        assert_no_difference "Collavre::OrchestratorPolicy.count" do
          patch collavre.admin_orchestration_path, params: { policies_yaml: yaml }
        end

        assert_response :unprocessable_entity
        assert_equal I18n.t("admin.orchestration.invalid_workflow_routing"), flash[:alert]
        assert_equal original_attributes, existing.reload.attributes
        assert_select "textarea[name='policies_yaml']", text: yaml
      end
    end

    %w[off shadow on].each do |mode|
      test "accepts quoted #{mode} workflow routing in #{scope}" do
        yaml = matching_yaml(scope, "workflow_routing: '#{mode}'")

        patch collavre.admin_orchestration_path, params: { policies_yaml: yaml }

        assert_redirected_to collavre.admin_orchestration_path
        policy = Collavre::OrchestratorPolicy.find_by!(policy_type: "matching")
        assert_equal mode, policy.config["workflow_routing"]
        assert_equal scope == "global", policy.global?
      end
    end

    test "accepts #{scope} matching config without workflow routing" do
      yaml = matching_yaml(scope, "trigger_expression: 'event.type == comment_created'")

      patch collavre.admin_orchestration_path, params: { policies_yaml: yaml }

      assert_redirected_to collavre.admin_orchestration_path
      policy = Collavre::OrchestratorPolicy.find_by!(policy_type: "matching")
      assert_equal({ "trigger_expression" => "event.type == comment_created" }, policy.config)
    end
  end

  test "explains workflow routing quoting in Korean" do
    @admin.update!(locale: "ko")
    patch collavre.admin_orchestration_path(locale: :ko), params: {
      policies_yaml: matching_yaml("global", "workflow_routing: on")
    }

    assert_response :unprocessable_entity
    assert_equal I18n.t("admin.orchestration.invalid_workflow_routing", locale: :ko), flash[:alert]
    assert_includes flash[:alert], "따옴표"
  end

  {
    "invalid_policy_structure" => { "matching" => "invalid" },
    "invalid_global_config" => { "matching" => { "global" => "invalid" } },
    "invalid_overrides" => { "matching" => { "overrides" => { "config" => {} } } },
    "invalid_override_format" => { "matching" => { "overrides" => [ "invalid" ] } },
    "invalid_override_config" => {
      "matching" => { "overrides" => [ { "scope_type" => "Topic", "scope_id" => 123, "config" => "invalid" } ] }
    }
  }.each do |error, policies|
    test "rejects matching #{error} before checking workflow routing" do
      patch collavre.admin_orchestration_path, params: { policies_yaml: policies.to_yaml }

      assert_response :unprocessable_entity
      assert_equal I18n.t("admin.orchestration.#{error}", type: "matching", index: 0), flash[:alert]
      assert_equal 0, Collavre::OrchestratorPolicy.count
    end
  end

  %w[matching arbitration scheduling collaboration].each do |type|
    %w[en ko].each do |locale|
      test "rejects blank non-array #{type} overrides and preserves policies and input in #{locale}" do
        @admin.update!(locale: locale)
        existing = Collavre::OrchestratorPolicy.create!(
          policy_type: "matching", config: { "workflow_routing" => "on" }
        )
        original = existing.attributes

        [ "", " \t\n", false, {} ].each do |overrides|
          yaml = { type => { "overrides" => overrides } }.to_yaml

          assert_no_difference "Collavre::OrchestratorPolicy.count" do
            patch collavre.admin_orchestration_path(locale: locale), params: { policies_yaml: yaml }
          end

          assert_response :unprocessable_entity
          assert_equal original, existing.reload.attributes
          assert_equal yaml, css_select("textarea[name='policies_yaml']").sole.text
          assert_equal I18n.t("admin.orchestration.invalid_overrides", locale: locale, type: type), flash[:alert]
        end
      end
    end

    { "omitted" => {}, "null" => { "overrides" => nil }, "empty array" => { "overrides" => [] } }.each do |label, data|
      test "accepts #{label} #{type} overrides" do
        config = { "custom_options" => { "enabled" => true } }
        yaml = { type => data.merge("global" => config) }.to_yaml

        patch collavre.admin_orchestration_path, params: { policies_yaml: yaml }

        assert_redirected_to collavre.admin_orchestration_path
        policy = Collavre::OrchestratorPolicy.sole
        assert_equal type, policy.policy_type
        assert policy.global?
        assert_equal config, policy.config
      end
    end
  end

  private

  def matching_yaml(scope, config)
    if scope == "global"
      "matching:\n  global:\n    #{config}\n"
    else
      "matching:\n  overrides:\n    - scope_type: Topic\n      scope_id: 123\n      config:\n        #{config}\n"
    end
  end
end
