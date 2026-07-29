# frozen_string_literal: true

require "test_helper"

# The default admin block in db/seeds.rb ships a published password. These pin
# the one environment where that must never reach the database.
class SeedsTest < ActiveSupport::TestCase
  DEFAULT_EMAIL = "admin@example.com"

  # Only the admin block — the engine seeds below it create users of their own
  # and are not what is under test here.
  SEEDS = File.read(Rails.root.join("db/seeds.rb"))
  ADMIN_BLOCK = SEEDS.split("# Load engine seeds").first.freeze
  raise "db/seeds.rb no longer marks where the engine seeds begin" if ADMIN_BLOCK == SEEDS

  setup do
    Collavre::User.where(email: DEFAULT_EMAIL).destroy_all
  end

  def seed_admin(env, **vars)
    original = vars.transform_values { nil }.merge(ENV.slice(*vars.keys.map(&:to_s)))
    vars.each { |k, v| ENV[k.to_s] = v }
    Rails.stub(:env, ActiveSupport::StringInquirer.new(env)) do
      capture_io { eval(ADMIN_BLOCK, TOPLEVEL_BINDING, "db/seeds.rb") } # rubocop:disable Security/Eval
    end
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
  end

  test "production without DEFAULT_USER_PASSWORD creates no admin" do
    out, = seed_admin("production", DEFAULT_USER_PASSWORD: nil, DEFAULT_USER_EMAIL: nil)

    assert_nil Collavre::User.find_by(email: DEFAULT_EMAIL),
      "a deployed host must not get a system_admin whose password is in the repository"
    assert_match(/DEFAULT_USER_PASSWORD is not set/, out)
  end

  test "production with a supplied password creates that admin" do
    seed_admin("production",
      DEFAULT_USER_EMAIL: "ops@example.org",
      DEFAULT_USER_PASSWORD: "a-password-the-operator-generated")

    user = Collavre::User.find_by(email: "ops@example.org")
    assert user, "an explicit password is the supported way to seed production"
    assert user.system_admin?
    assert user.authenticate("a-password-the-operator-generated")
  ensure
    Collavre::User.where(email: "ops@example.org").destroy_all
  end

  test "an empty DEFAULT_USER_PASSWORD is not a password" do
    # Kamal and dotenv both hand through declared-but-empty variables.
    seed_admin("production", DEFAULT_USER_PASSWORD: "", DEFAULT_USER_EMAIL: nil)

    assert_nil Collavre::User.find_by(email: DEFAULT_EMAIL)
  end

  test "development still seeds the default admin" do
    seed_admin("development", DEFAULT_USER_PASSWORD: nil, DEFAULT_USER_EMAIL: nil)

    user = Collavre::User.find_by(email: DEFAULT_EMAIL)
    assert user, "the convenience default is the point outside production"
    assert user.authenticate("password123")
  end
end
