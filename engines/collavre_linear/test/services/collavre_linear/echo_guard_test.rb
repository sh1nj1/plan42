# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class EchoGuardTest < ActiveSupport::TestCase
    # ---------------------------------------------------------------------------
    # Helpers — pure Ruby stubs, no DB required for our_event? tests
    # ---------------------------------------------------------------------------

    AccountStub = Struct.new(:app_actor_id, keyword_init: true)

    def make_account(app_actor_id: "actor-abc")
      AccountStub.new(app_actor_id: app_actor_id)
    end

    def make_payload(actor_id: "actor-abc")
      { "actor" => { "id" => actor_id } }
    end

    # ---------------------------------------------------------------------------
    # our_event?  — primary actor-id check
    # ---------------------------------------------------------------------------

    test "our_event? returns true when actor.id equals account.app_actor_id" do
      account = make_account(app_actor_id: "actor-abc")
      payload = make_payload(actor_id: "actor-abc")

      assert EchoGuard.our_event?(account, payload)
    end

    test "our_event? returns false when actor.id differs from app_actor_id" do
      account = make_account(app_actor_id: "actor-abc")
      payload = make_payload(actor_id: "actor-xyz")

      assert_not EchoGuard.our_event?(account, payload)
    end

    test "our_event? returns false when payload is nil" do
      account = make_account
      assert_not EchoGuard.our_event?(account, nil)
    end

    test "our_event? returns false when payload has no actor key" do
      account = make_account
      assert_not EchoGuard.our_event?(account, { "type" => "Issue" })
    end

    test "our_event? returns false when actor is nil" do
      account = make_account
      assert_not EchoGuard.our_event?(account, { "actor" => nil })
    end

    test "our_event? returns false when account.app_actor_id is nil" do
      account = make_account(app_actor_id: nil)
      payload = make_payload(actor_id: "actor-abc")

      assert_not EchoGuard.our_event?(account, payload)
    end

    test "our_event? never raises on bizarre payload shapes" do
      account = make_account
      [nil, {}, { "actor" => {} }, { "actor" => { "id" => nil } }].each do |p|
        assert_nothing_raised { EchoGuard.our_event?(account, p) }
      end
    end

    # ---------------------------------------------------------------------------
    # record_outbound — secondary window guard (DB-backed)
    # ---------------------------------------------------------------------------

    test "record_outbound stamps last_outbound_at on the link" do
      user = Collavre.user_class.create!(
        email: "echo-guard-test@example.com",
        name: "Echo Guard Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      creative = Collavre::Creative.create!(
        description: "<p>Echo guard test creative</p>",
        user: user
      )
      account = CollavreLinear::Account.create!(
        user: user,
        linear_uid: "usr_echo_guard",
        access_token: "tok",
        app_actor_id: "actor-abc"
      )
      project_link = CollavreLinear::ProjectLink.create!(
        creative: creative,
        account: account,
        linear_project_id: "proj-eg",
        team_id: "team-eg"
      )

      before = Time.current
      EchoGuard.record_outbound(project_link, "iss-1")
      project_link.reload

      assert_not_nil project_link.last_outbound_at
      assert project_link.last_outbound_at >= before
    end
  end
end
