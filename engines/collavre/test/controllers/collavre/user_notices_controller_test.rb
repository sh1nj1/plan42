require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class UserNoticesControllerTest < ActionDispatch::IntegrationTest
    include NoticeTestHelpers

    setup do
      isolate_notice_registry
      NoticeRegistry.register(:tour_one, kind: :mission, group: :tour, done_when: ->(_user) { false })
      NoticeRegistry.register(:release_note, kind: :feature)
      NoticeRegistry.register(:admins_only, audience: ->(user) { user.system_admin? })
      @user = users(:two)
      sign_in_as(@user, password: "password")
    end

    teardown { restore_notice_registry }

    def state(key)
      UserNotice.find_by(user: @user, notice_key: key)
    end

    test "snoozes missions and dismisses everything else" do
      post "/user_notices/tour_one/snooze"
      assert_response :no_content
      assert state("tour_one").snoozed?
      assert_in_delta UserNotice::SNOOZE_DURATION.from_now, state("tour_one").snoozed_until, 5.seconds

      post "/user_notices/release_note/dismiss"
      assert_response :no_content
      assert state("release_note").dismissed?
    end

    test "rejects dismissing a mission or snoozing a non-mission" do
      post "/user_notices/tour_one/dismiss"
      assert_response :unprocessable_entity
      post "/user_notices/release_note/snooze"
      assert_response :unprocessable_entity
      assert_nil state("tour_one")
    end

    test "completes only non-mission notices" do
      post "/user_notices/release_note/complete"
      assert_response :no_content
      assert state("release_note").completed?

      post "/user_notices/tour_one/complete"
      assert_response :unprocessable_entity
    end

    test "restores a snooze or dismissal but nothing else" do
      post "/user_notices/tour_one/restore"
      assert_response :unprocessable_entity

      post "/user_notices/tour_one/snooze"
      post "/user_notices/tour_one/restore"
      assert_response :no_content
      assert state("tour_one").pending?
      assert_nil state("tour_one").snoozed_until
    end

    test "404s for unknown notices and ones outside the audience" do
      post "/user_notices/nope/dismiss"
      assert_response :not_found
      post "/user_notices/admins_only/dismiss"
      assert_response :not_found
    end
  end

  class UserNoticesSignedOutTest < ActionDispatch::IntegrationTest
    test "requires a session" do
      post "/user_notices/onboarding_first_creative/snooze"
      assert_response :redirect
    end
  end
end
