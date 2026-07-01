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

  test "linear_project_id is globally unique across creatives" do
    CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "dup-proj",
      team_id: "team-dup"
    )
    # A DISJOINT creative claiming the same Linear project must be rejected at
    # the DB layer, not just by the controller's check-then-save: inbound
    # webhooks resolve the project via an unscoped find_by(linear_project_id:),
    # so two links on one project would route imports nondeterministically.
    other = Collavre::Creative.create!(description: "<p>other root</p>", user: @user)
    dup = CollavreLinear::ProjectLink.new(
      creative: other,
      account: @account,
      linear_project_id: "dup-proj",
      team_id: "team-dup",
      webhook_secret: "explicit-secret"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "webhook_secret is stored encrypted at rest" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-enc",
      team_id: "team-enc"
    )
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT webhook_secret FROM linear_project_links WHERE id = #{link.id}"
    )
    assert link.webhook_secret.present?
    assert_not_equal link.webhook_secret, raw,
      "the HMAC signing secret must not be persisted in plaintext"
  end

  test "sibling ProjectLinks for a team share one secret even when encrypted" do
    first = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-share-a",
      team_id: "team-share"
    )
    c2 = Collavre::Creative.create!(description: "<p>c2</p>", user: @user)
    second = CollavreLinear::ProjectLink.create!(
      creative: c2,
      account: @account,
      linear_project_id: "proj-share-b",
      team_id: "team-share"
    )
    assert_equal first.webhook_secret, second.webhook_secret,
      "the manual single team webhook needs all links to verify with the same secret"
  end

  test "rotate_webhook_secret! rolls the secret for the link and every team sibling" do
    first = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-rot-a",
      team_id: "team-rot"
    )
    c2 = Collavre::Creative.create!(description: "<p>c2</p>", user: @user)
    sibling = CollavreLinear::ProjectLink.create!(
      creative: c2,
      account: @account,
      linear_project_id: "proj-rot-b",
      team_id: "team-rot"
    )
    old_secret = first.webhook_secret
    assert_equal old_secret, sibling.webhook_secret

    new_secret = first.rotate_webhook_secret!

    assert_not_equal old_secret, new_secret
    assert_match(/\A[0-9a-f]{40}\z/, new_secret)
    assert_equal new_secret, first.webhook_secret
    assert_equal new_secret, sibling.reload.webhook_secret,
      "the team shares one secret Linear signs with — siblings must roll together or 401"

    # update_column must still apply encryption; a raw write would leak plaintext.
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT webhook_secret FROM linear_project_links WHERE id = #{first.id}"
    )
    assert_not_equal new_secret, raw, "the rolled secret must remain encrypted at rest"
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
