require "test_helper"

# Covers the desktop first-run admin bootstrap and, critically, its open-mode
# guard: when the app is bound to a LAN/Tailscale interface, a remote signup
# must not be able to claim the initial system_admin account ahead of the owner.
class FirstAdminBootstrapTest < ActionDispatch::IntegrationTest
  setup do
    @original = Rails.application.config.x.bootstrap_first_admin
    Rails.application.config.x.bootstrap_first_admin = true
    # Start from "no admin yet" regardless of fixtures (rolled back after test).
    Collavre::User.where(system_admin: true).update_all(system_admin: false)
  end

  teardown do
    Rails.application.config.x.bootstrap_first_admin = @original
  end

  def sign_up(email, remote_addr:)
    post users_path,
      params: { user: { email: email, password: TEST_PASSWORD, password_confirmation: TEST_PASSWORD, name: email } },
      env: { "REMOTE_ADDR" => remote_addr }
    Collavre::User.find_by(email: email)
  end

  test "first loopback signup is elevated to system_admin" do
    owner = sign_up("owner@example.com", remote_addr: "127.0.0.1")
    assert owner.system_admin?, "the local owner's first signup should bootstrap admin"
  end

  test "remote signup in open mode is not elevated to system_admin" do
    remote = sign_up("remote@example.com", remote_addr: "100.101.102.103")
    assert_not remote.system_admin?, "a remote LAN/Tailscale signup must not claim the first admin"
    assert_not Collavre::User.exists?(system_admin: true), "no admin should be bootstrapped from a remote origin"
  end

  test "spoofed X-Forwarded-For loopback from a LAN peer is not elevated" do
    post users_path,
      params: { user: { email: "spoof@example.com", password: TEST_PASSWORD, password_confirmation: TEST_PASSWORD, name: "spoof" } },
      env: { "REMOTE_ADDR" => "192.168.1.50" },
      headers: { "X-Forwarded-For" => "127.0.0.1" }
    assert_not Collavre::User.find_by(email: "spoof@example.com").system_admin?,
      "remote_addr is the socket peer; a forged XFF loopback must not elevate"
  end

  test "second signup is not elevated once an admin exists" do
    owner = sign_up("owner2@example.com", remote_addr: "127.0.0.1")
    second = sign_up("second@example.com", remote_addr: "127.0.0.1")
    assert owner.system_admin?
    assert_not second.system_admin?
    assert_equal 1, Collavre::User.where(system_admin: true).count
  end

  # The atomic promotion is a single UPDATE scoped to the new user. Guards against
  # a mis-scoped update_all elevating every pre-existing non-admin user at once.
  test "only the new signup is elevated, not existing non-admin users" do
    bystander = Collavre::User.create!(
      email: "bystander@example.com", password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD, name: "bystander"
    )
    owner = sign_up("owner3@example.com", remote_addr: "127.0.0.1")
    assert owner.system_admin?, "the first loopback signup should bootstrap admin"
    assert_not bystander.reload.system_admin?, "a pre-existing user must not be swept into admin"
    assert_equal 1, Collavre::User.where(system_admin: true).count
  end
end
