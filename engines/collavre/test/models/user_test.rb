require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "requires valid email" do
    user = User.new(email: "bad", password: "password123", password_confirmation: "password123", name: "Bad")
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "requires unique email" do
    User.create!(email: "taken@example.com", password: "password123", name: "Taken")
    user = User.new(email: "taken@example.com", password: "password123", name: "Taken")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end

  test "requires password minimum length" do
    user = User.new(email: "short@example.com", password: "short", name: "Short")
    assert_not user.valid?
    assert user.errors.of_kind?(:password, :too_short),
      "Expected :too_short error on password"
  end

  test "accepts password meeting minimum length" do
    user = User.new(email: "long@example.com", password: "password123", name: "Long")
    user.valid?
    assert_not user.errors.of_kind?(:password, :too_short),
      "Should not have :too_short error for valid password"
  end

  test "enforces custom password minimum length from system setting" do
    # Set custom min length
    SystemSetting.find_or_create_by!(key: "password_min_length").update!(value: "12")
    Rails.cache.clear

    # 10 chars should fail when min is 12
    user = User.new(email: "custom@example.com", password: "1234567890", name: "Custom")
    assert_not user.valid?
    assert user.errors.of_kind?(:password, :too_short)

    # 12 chars should pass
    user.password = "123456789012"
    user.valid?
    assert_not user.errors.of_kind?(:password, :too_short)
  end

  test "password min length is capped at 72 (bcrypt limit)" do
    # Even if DB has value > 72, it should be capped
    SystemSetting.find_or_create_by!(key: "password_min_length").update!(value: "100")
    Rails.cache.clear

    assert_equal 72, SystemSetting.password_min_length,
      "password_min_length should be capped at 72"

    # 72-char password should pass
    user = User.new(email: "max@example.com", password: "a" * 72, name: "Max")
    user.valid?
    assert_not user.errors.of_kind?(:password, :too_short),
      "72-char password should pass when min is capped at 72"
  end

  test "bounds AI vendor and model lengths" do
    user = User.new(
      email: "bounded-agent@example.com",
      password: "password123",
      name: "Bounded Agent",
      llm_vendor: "v" * Collavre::LlmModel::MAX_VENDOR_LENGTH,
      llm_model: "m" * Collavre::LlmModel::MAX_NAME_LENGTH
    )

    user.save!
    assert_predicate user, :persisted?

    user.llm_vendor = "v" * (Collavre::LlmModel::MAX_VENDOR_LENGTH + 1)
    assert_not user.valid?
    assert user.errors.of_kind?(:llm_vendor, :too_long)

    user.llm_vendor = "vendor"
    user.llm_model = "m" * (Collavre::LlmModel::MAX_NAME_LENGTH + 1)
    assert_not user.valid?
    assert user.errors.of_kind?(:llm_model, :too_long)
  end

  test "allows unrelated updates for a legacy AI user with oversized fields" do
    user = User.create!(
      email: "legacy-agent@example.com",
      password: "password123",
      name: "Legacy Agent",
      llm_vendor: "vendor",
      llm_model: "model"
    )
    user.update_columns(
      llm_vendor: "v" * (Collavre::LlmModel::MAX_VENDOR_LENGTH + 1),
      llm_model: "m" * (Collavre::LlmModel::MAX_NAME_LENGTH + 1)
    )

    user.name = "Renamed Legacy Agent"

    assert user.save
  end

  test "nullifies shares created by user as sharer when destroyed" do
    sharer = users(:two)
    recipient = users(:three)
    creative = creatives(:tshirt)

    share = CreativeShare.create!(creative: creative, user: recipient, shared_by: sharer, permission: :read)

    assert_nothing_raised { sharer.destroy! }
    assert_nil share.reload.shared_by_id
  end

  test "CLI Proxy agents require a gateway owned by their creator" do
    owner = users(:two)
    gateway = Collavre::AgentGateway.create!(
      owner: users(:three),
      name: "Foreign gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
    agent = Collavre::User.new(
      name: "Invalid CLI agent",
      email: "invalid-cli-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )

    assert_not agent.valid?
    assert agent.errors.of_kind?(:agent_gateway, :invalid)
  end

  test "CLI Proxy agents require a gateway completion key" do
    owner = users(:two)
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Provisioning-only gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin"
    )
    agent = Collavre::User.new(
      name: "Keyless CLI agent",
      email: "keyless-cli-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )

    assert_not agent.valid?
    assert agent.errors.of_kind?(:agent_gateway, :completion_key_required)
  end

  test "a secretless shared gateway cannot be assigned to a second CLI Proxy agent" do
    owner = users(:two)
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Single-agent gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
    first_agent = Collavre::User.create!(
      name: "First CLI agent",
      email: "first-secretless-cli-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )
    second_agent = first_agent.dup
    second_agent.email = "second-secretless-cli-agent@ai.local"

    assert_not second_agent.valid?
    assert second_agent.errors.of_kind?(:agent_gateway, :identity_required)
  end

  test "gateway access follows inherited creative permissions" do
    owner = users(:two)
    viewer = Collavre::User.create!(
      email: "inherited-gateway-viewer@example.com",
      password: TEST_PASSWORD,
      name: "Inherited Gateway Viewer"
    )
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Inherited permission gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "i" * 32,
      workspace_mode: :per_user
    )
    agent = Collavre::User.create!(
      name: "Inherited permission agent",
      email: "inherited-permission-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )

    child = perform_enqueued_jobs do
      root = Collavre::Creative.create!(user: owner, description: "Shared root")
      nested = Collavre::Creative.create!(user: owner, parent: root, description: "Nested agent creative")
      Collavre::CreativeShare.create!(creative: root, user: viewer, permission: :read)
      Collavre::CreativeShare.create!(creative: nested, user: agent, permission: :feedback)
      nested
    end

    assert child.has_permission?(viewer, :read)
    assert agent.gateway_accessible_to?(viewer)
  end

  test "gateway access includes creatives owned by the agent" do
    owner = users(:two)
    viewer = Collavre::User.create!(
      email: "agent-owned-gateway-viewer@example.com",
      password: TEST_PASSWORD,
      name: "Agent-owned Gateway Viewer"
    )
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Agent-owned creative gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "i" * 32,
      workspace_mode: :per_user
    )
    agent = Collavre::User.create!(
      name: "Agent-owned creative agent",
      email: "agent-owned-creative-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )

    creative = perform_enqueued_jobs do
      creative = Collavre::Creative.create!(user: agent, description: "Agent-owned root")
      Collavre::CreativeShare.create!(creative: creative, user: viewer, permission: :read)
      creative
    end

    assert creative.has_permission?(viewer, :read)
    assert agent.gateway_accessible_to?(viewer)
  end

  test "gateway access follows public feedback permission for the agent" do
    owner = users(:two)
    viewer = users(:three)
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Public permission gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "i" * 32,
      workspace_mode: :per_user
    )
    agent = Collavre::User.create!(
      name: "Public permission agent",
      email: "public-permission-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )

    creative = perform_enqueued_jobs do
      creative = Collavre::Creative.create!(user: owner, description: "Public feedback creative")
      Collavre::CreativeShare.create!(creative: creative, user: nil, permission: :feedback)
      creative
    end

    assert creative.has_permission?(agent, :feedback)
    assert creative.has_permission?(viewer, :read)
    assert agent.gateway_accessible_to?(viewer)
  end

  test "explicit agent denial overrides public feedback for gateway access" do
    owner = users(:two)
    viewer = users(:three)
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Denied public permission gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "i" * 32,
      workspace_mode: :per_user
    )
    agent = Collavre::User.create!(
      name: "Denied public permission agent",
      email: "denied-public-permission-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: owner.id,
      agent_gateway: gateway
    )

    creative = perform_enqueued_jobs do
      creative = Collavre::Creative.create!(user: owner, description: "Denied public creative")
      Collavre::CreativeShare.create!(creative: creative, user: nil, permission: :feedback)
      Collavre::CreativeShare.create!(creative: creative, user: agent, permission: :no_access)
      creative
    end

    refute creative.has_permission?(agent, :feedback)
    assert creative.has_permission?(viewer, :read)
    refute agent.gateway_accessible_to?(viewer)
  end
end
