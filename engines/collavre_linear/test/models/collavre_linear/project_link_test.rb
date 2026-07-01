# frozen_string_literal: true

require_relative "../../test_helper"

class CollavreLinear::ProjectLinkTest < ActiveSupport::TestCase
  def setup
    @user = Collavre.user_class.create!(
      email: "pl-test@example.com",
      name: "PL Test User",
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
    @creative = Collavre::Creative.create!(
      description: "<p>Root creative</p>",
      user: @user
    )
    @account = CollavreLinear::Account.create!(
      user: @user,
      linear_uid: "uid-pl",
      access_token: "token-pl"
    )
  end

  test "webhook_secret is auto-generated on validation" do
    link = CollavreLinear::ProjectLink.new(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-1",
      team_id: "team-1"
    )
    assert_nil link.webhook_secret
    link.valid?
    assert_not_nil link.webhook_secret
    assert_match(/\A[0-9a-f]{40}\z/, link.webhook_secret)
  end

  test "webhook_secret is not regenerated if already present" do
    link = CollavreLinear::ProjectLink.new(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-2",
      team_id: "team-2",
      webhook_secret: "existing-secret"
    )
    link.valid?
    assert_equal "existing-secret", link.webhook_secret
  end

  test "sync_state defaults to synced" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-3",
      team_id: "team-3"
    )
    assert_equal "synced", link.sync_state
  end

  test "sync_state enum rejects unknown values" do
    link = CollavreLinear::ProjectLink.new(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-4",
      team_id: "team-4",
      sync_state: "synced"
    )
    assert_raises(ArgumentError) { link.sync_state = "invalid_state" }
  end

  test "auto_syncable scope includes synced and dirty" do
    synced = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-5",
      team_id: "team-5",
      sync_state: :synced
    )
    c2 = Collavre::Creative.create!(description: "<p>c2</p>", user: @user)
    dirty = CollavreLinear::ProjectLink.create!(
      creative: c2,
      account: @account,
      linear_project_id: "proj-6",
      team_id: "team-6",
      sync_state: :dirty
    )
    c3 = Collavre::Creative.create!(description: "<p>c3</p>", user: @user)
    syncing = CollavreLinear::ProjectLink.create!(
      creative: c3,
      account: @account,
      linear_project_id: "proj-7",
      team_id: "team-7",
      sync_state: :syncing
    )
    ids = CollavreLinear::ProjectLink.auto_syncable.pluck(:id)
    assert_includes ids, synced.id
    assert_includes ids, dirty.id
    refute_includes ids, syncing.id
  end

  test "unique index on (creative_id, linear_project_id)" do
    CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "dup-proj",
      team_id: "team-dup"
    )
    dup = CollavreLinear::ProjectLink.new(
      creative: @creative,
      account: @account,
      linear_project_id: "dup-proj",
      team_id: "team-dup",
      webhook_secret: "explicit-secret"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "belongs to creative and account" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-assoc",
      team_id: "team-assoc"
    )
    assert_equal @creative, link.creative
    assert_equal @account, link.account
  end
end
