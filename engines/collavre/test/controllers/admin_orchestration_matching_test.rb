# frozen_string_literal: true

require "test_helper"

class AdminOrchestrationMatchingTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one), password: "password")
  end

  test "empty policy editor defaults workflow routing to shadow" do
    get collavre.admin_orchestration_path

    assert_response :success
    assert_equal "shadow", editor_policies.dig("matching", "global", "workflow_routing")
  end

  test "upgraded policy editor adds shadow matching and preserves other policies through editing" do
    existing = {
      "arbitration" => { "global" => { "strategy" => "all", "max_responders" => 2 } },
      "scheduling" => { "global" => { "max_concurrent_jobs" => 5 } },
      "collaboration" => { "global" => { "mention_rule" => "Keep existing instructions" } }
    }
    existing.each do |type, data|
      Collavre::OrchestratorPolicy.create!(policy_type: type, config: data["global"])
    end

    get collavre.admin_orchestration_path

    assert_response :success
    policies = editor_policies
    assert_equal existing, policies.except("matching")
    assert_equal({ "global" => { "workflow_routing" => "shadow" } }, policies["matching"])
    policies["scheduling"]["global"]["max_concurrent_jobs"] = 3

    patch collavre.admin_orchestration_path, params: { policies_yaml: policies.to_yaml }

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal "shadow", workflow_mode({})
    get collavre.admin_orchestration_path

    assert_response :success
    assert_equal policies, editor_policies
  end

  test "existing scoped matching section is preserved without adding a global default" do
    create_matching_policy(mode: "on", scope_type: "Creative", scope_id: creatives(:tshirt).id, priority: 71)
    original_matching = matching_snapshot

    get collavre.admin_orchestration_path

    assert_response :success
    policies = editor_policies
    refute policies["matching"].key?("global")
    assert_equal "on", policies["matching"]["overrides"].sole.dig("config", "workflow_routing")

    patch collavre.admin_orchestration_path, params: { policies_yaml: policies.to_yaml }

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal original_matching, matching_snapshot
  end

  %w[off shadow on].each do |mode|
    test "saves global workflow routing #{mode} as a string" do
      policies = { "matching" => { "global" => { "workflow_routing" => mode } } }

      patch collavre.admin_orchestration_path, params: { policies_yaml: policies.to_yaml }

      assert_redirected_to collavre.admin_orchestration_path
      policy = Collavre::OrchestratorPolicy.for_type("matching").global.sole
      assert_equal mode, policy.config["workflow_routing"]
      assert_instance_of String, policy.config["workflow_routing"]
      assert_equal mode, workflow_mode({})

      get collavre.admin_orchestration_path

      assert_response :success
      assert_equal policies, editor_policies
    end
  end

  test "editing scheduling preserves matching configuration and scoped workflow modes" do
    creative = creatives(:tshirt)
    topic = Collavre::Topic.create!(name: "Matching editor", creative: creative, user: users(:one))
    create_matching_policy(mode: "off", priority: 100)
    create_matching_policy(mode: "on", scope_type: "Creative", scope_id: creative.id, priority: 71)
    create_matching_policy(mode: "shadow", scope_type: "Topic", scope_id: topic.id, priority: 22)
    Collavre::OrchestratorPolicy.create!(policy_type: "scheduling", config: { "max_concurrent_jobs" => 5 })
    original_matching = matching_snapshot
    contexts = [
      {},
      { "creative" => { "id" => creative.id } },
      { "creative" => { "id" => creative.id }, "topic" => { "id" => topic.id },
        "user" => { "id" => users(:ai_bot).id } }
    ]
    original_modes = contexts.map { |context| workflow_mode(context) }
    assert_equal %w[off on shadow], original_modes

    get collavre.admin_orchestration_path

    assert_response :success
    policies = editor_policies
    policies["scheduling"]["global"]["max_concurrent_jobs"] = 3

    patch collavre.admin_orchestration_path, params: { policies_yaml: policies.to_yaml }

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal 3, Collavre::OrchestratorPolicy.for_type("scheduling").global.sole.config["max_concurrent_jobs"]
    assert_equal original_matching, matching_snapshot
    assert_equal original_modes, contexts.map { |context| workflow_mode(context) }
  end

  test "editing scheduling preserves the merged configuration of multiple global matching policies" do
    Collavre::OrchestratorPolicy.create!(
      policy_type: "matching", priority: 20,
      config: { "custom_options" => { "enabled" => true } }
    )
    Collavre::OrchestratorPolicy.create!(
      policy_type: "matching", priority: 10,
      config: { "workflow_routing" => "off", "custom_options" => { "enabled" => false, "old_option" => true } }
    )
    Collavre::OrchestratorPolicy.create!(policy_type: "scheduling", config: { "max_concurrent_jobs" => 5 })
    expected_config = { "workflow_routing" => "off", "custom_options" => { "enabled" => true } }
    assert_equal expected_config, Collavre::Orchestration::PolicyResolver.new({}).resolve("matching")
    assert_equal "off", workflow_mode({})

    get collavre.admin_orchestration_path

    assert_response :success
    policies = editor_policies
    policies["scheduling"]["global"]["max_concurrent_jobs"] = 3

    patch collavre.admin_orchestration_path, params: { policies_yaml: policies.to_yaml }

    assert_redirected_to collavre.admin_orchestration_path
    assert_equal 3, Collavre::OrchestratorPolicy.for_type("scheduling").global.sole.config["max_concurrent_jobs"]
    assert_equal expected_config, Collavre::OrchestratorPolicy.for_type("matching").global.sole.config
    assert_equal expected_config, Collavre::Orchestration::PolicyResolver.new({}).resolve("matching")
    assert_equal "off", workflow_mode({})
  end

  %w[en ko].each do |locale|
    test "rejects User matching overrides and preserves policies and input in #{locale}" do
      users(:one).update!(locale: locale)
      existing = Collavre::OrchestratorPolicy.create!(
        policy_type: "scheduling", config: { "max_concurrent_jobs" => 5 }
      )
      original = existing.attributes
      yaml = {
        "matching" => {
          "global" => { "workflow_routing" => "off" },
          "overrides" => [ {
            "scope_type" => "User", "scope_id" => users(:ai_bot).id,
            "config" => { "workflow_routing" => "on" }
          } ]
        }
      }.to_yaml

      assert_no_difference "Collavre::OrchestratorPolicy.count" do
        patch collavre.admin_orchestration_path(locale: locale), params: { policies_yaml: yaml }
      end

      assert_response :unprocessable_entity
      assert_equal original, existing.reload.attributes
      assert_equal yaml, css_select("textarea[name='policies_yaml']").sole.text
      assert_equal I18n.t("admin.orchestration.invalid_scope_type", locale: locale,
                         type: "matching", index: 0, scope_type: "User", scopes: "Creative, Topic"), flash[:alert]
    end
  end

  %w[arbitration scheduling collaboration].each do |type|
    test "continues to save User overrides for #{type}" do
      config = { "custom_options" => { "enabled" => true } }
      yaml = { type => { "overrides" => [ {
        "scope_type" => "User", "scope_id" => users(:ai_bot).id, "config" => config
      } ] } }.to_yaml

      patch collavre.admin_orchestration_path, params: { policies_yaml: yaml }

      assert_redirected_to collavre.admin_orchestration_path
      policy = Collavre::OrchestratorPolicy.sole
      assert_equal type, policy.policy_type
      assert_equal "User", policy.scope_type
      assert_equal users(:ai_bot).id, policy.scope_id
      assert_equal config, policy.config
    end
  end

  private

  def editor_policies
    YAML.safe_load(css_select("textarea[name='policies_yaml']").sole.text)
  end

  def create_matching_policy(mode:, priority:, scope_type: nil, scope_id: nil)
    Collavre::OrchestratorPolicy.create!(
      policy_type: "matching", scope_type: scope_type, scope_id: scope_id, priority: priority,
      config: { "workflow_routing" => mode, "custom_options" => { "enabled" => true } }
    )
  end

  def matching_snapshot
    Collavre::OrchestratorPolicy.for_type("matching").order(:priority)
      .pluck(:scope_type, :scope_id, :priority, :config)
  end

  def workflow_mode(context)
    Collavre::Orchestration::PolicyResolver.new(context).workflow_routing_mode
  end
end
