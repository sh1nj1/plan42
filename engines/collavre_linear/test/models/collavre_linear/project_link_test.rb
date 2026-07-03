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

  test "webhook_secret stays blank until pasted — we never mint our own" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-1",
      team_id: "team-1"
    )
    # Linear owns the signing secret (it generates one per webhook), so a fresh
    # link carries none until the admin pastes Linear's value.
    assert_nil link.webhook_secret
  end

  test "an explicitly provided webhook_secret is preserved" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-2",
      team_id: "team-2",
      webhook_secret: "linear-generated-secret"
    )
    assert_equal "linear-generated-secret", link.webhook_secret
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

  test "creative_id is globally unique — one Collavre root links at most one project" do
    CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "root-proj-a",
      team_id: "team-root"
    )
    # The SAME root linking a SECOND, different Linear project must be rejected at
    # the DB layer, not only by the controller's check-then-save origin_conflict
    # guard: two concurrent link requests for one root to different projects could
    # both pass that check, and resolve_project_link (find_by creative_id) would
    # then sync against whichever ProjectLink the DB returns.
    dup = CollavreLinear::ProjectLink.new(
      creative: @creative,
      account: @account,
      linear_project_id: "root-proj-b",
      team_id: "team-root",
      webhook_secret: "explicit-secret"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "webhook_secret is stored encrypted at rest" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-enc",
      team_id: "team-enc",
      webhook_secret: "plaintext-signing-secret"
    )
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT webhook_secret FROM linear_project_links WHERE id = #{link.id}"
    )
    assert link.webhook_secret.present?
    assert_not_equal link.webhook_secret, raw,
      "the HMAC signing secret must not be persisted in plaintext"
  end

  test "a second project of a team adopts the team's pasted secret on create" do
    # One Linear webhook per team = one secret, so a later project of the same
    # team inherits the sibling's pasted value instead of asking the admin to
    # paste it again. Adopt reads the DECRYPTED attribute (a raw ciphertext pick
    # would double-encrypt into an HMAC mismatch).
    CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-share-a",
      team_id: "team-share",
      webhook_secret: "team-signing-secret"
    )
    c2 = Collavre::Creative.create!(description: "<p>c2</p>", user: @user)
    second = CollavreLinear::ProjectLink.create!(
      creative: c2,
      account: @account,
      linear_project_id: "proj-share-b",
      team_id: "team-share"
    )
    assert_equal "team-signing-secret", second.webhook_secret,
      "the manual single team webhook needs all links to verify with the same secret"
  end

  test "a brand-new team's first link adopts nothing (stays blank)" do
    link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-fresh",
      team_id: "team-fresh"
    )
    assert_nil link.webhook_secret
  end

  test "update_webhook_secret! stores the pasted secret on the link and every team sibling" do
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
    assert_nil first.webhook_secret
    assert_nil sibling.webhook_secret

    returned = first.update_webhook_secret!("pasted-linear-secret")

    assert_equal "pasted-linear-secret", returned
    assert_equal "pasted-linear-secret", first.webhook_secret
    assert_equal "pasted-linear-secret", sibling.reload.webhook_secret,
      "the team shares one secret Linear signs with — siblings must match or 401"

    # update_column must still apply encryption; a raw write would leak plaintext.
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT webhook_secret FROM linear_project_links WHERE id = #{first.id}"
    )
    assert_not_equal "pasted-linear-secret", raw, "the stored secret must remain encrypted at rest"
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
