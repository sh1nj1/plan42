require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class OnboardingReplaysControllerTest < ActionDispatch::IntegrationTest
    include NoticeTestHelpers

    setup do
      isolate_notice_registry
      %i[first second third].each do |key|
        NoticeRegistry.register(key, kind: :mission, group: :onboarding,
          done_when: ->(_) { true }, completes_on: { "replay_step.collavre" => ->(payload) { payload[:step] == key } })
      end
      NoticeRegistry.register(:announcement, group: :onboarding)
      NoticeRegistry.register(:other_mission, kind: :mission, group: :other, done_when: ->(_) { false })
      @user = users(:two)
    end

    teardown { restore_notice_registry }

    test "restarts all steps without changing another user or other notices" do
      UserNotice.record!(@user, :first, :completed)
      UserNotice.record!(@user, :second, :snoozed, snoozed_until: 1.day.from_now)
      UserNotice.record!(@user, :third, :dismissed)
      UserNotice.record!(@user, :announcement, :dismissed)
      UserNotice.record!(@user, :other_mission, :completed)
      other = UserNotice.record!(users(:one), :first, :completed)
      sign_in_as(@user, password: "password")

      post collavre.onboarding_replay_path, params: { user_id: users(:one).id }

      assert_response :see_other
      assert_redirected_to collavre.creatives_path
      assert_equal %w[first second third], UserNotice.pending.where(user: @user).order(:id).pluck(:notice_key)
      assert UserNotice.where(user: @user, notice_key: %w[first second third]).all? { |row| row.completed_at.nil? && row.snoozed_until.nil? }
      assert other.reload.completed?
      assert UserNotice.find_by!(user: @user, notice_key: :announcement).dismissed?
      assert UserNotice.find_by!(user: @user, notice_key: :other_mission).completed?
      follow_redirect!
      assert_response :success
      assert_select "#notice-bar-payload" do |payload|
        assert_equal %w[first], JSON.parse(payload.first["data-items"]).map { |item| item["key"] }
      end
    end

    test "seeds missing steps and advances only through new completion events" do
      sign_in_as(@user, password: "password")
      post collavre.onboarding_replay_path
      assert_response :see_other
      assert_equal 3, UserNotice.pending.where(user: @user).count
      assert_equal %w[first other_mission announcement], Notices::Feed.new(@user).items.map { |item| item[:key] }
      Notices::Tracker.handle("replay_step.collavre", user: @user, step: :first)
      assert UserNotice.find_by!(user: @user, notice_key: :first).completed?
      assert UserNotice.find_by!(user: @user, notice_key: :second).pending?
      assert_equal "second", Notices::Feed.new(@user).items.first[:key]
      post collavre.onboarding_replay_path
      assert_response :see_other
      assert_equal 3, UserNotice.pending.where(user: @user, notice_key: %w[first second third]).count
    end

    test "an empty registry is a safe no-op" do
      NoticeRegistry.reset!
      sign_in_as(@user, password: "password")
      assert_no_difference "UserNotice.count" do
        post collavre.onboarding_replay_path
      end
      assert_response :see_other
    end

    test "requires authentication and cannot restart through a GET" do
      assert_no_difference "UserNotice.count" do
        post collavre.onboarding_replay_path
      end
      assert_redirected_to collavre.new_session_path
      sign_in_as(@user, password: "password")
      assert_no_difference "UserNotice.count" do
        get collavre.onboarding_replay_path
      end
      assert_response :not_found
    end

    test "own profile ends with a localized POST replay link in both languages" do
      sign_in_as(@user, password: "password")
      %i[en ko].each do |locale|
        @user.update!(locale: locale)
        get collavre.user_path(@user)
        assert_response :success
        assert_select ".profile-actions a:last-child[href=?][data-turbo-method=post]", collavre.onboarding_replay_path,
          text: I18n.t("collavre.notices.replay.link", locale: locale)
      end
    end

    test "other profiles including agents have no replay link" do
      sign_in_as(@user, password: "password")
      [ users(:one), users(:ai_bot) ].each do |other|
        get collavre.user_path(other)
        assert_response :success
        assert_select "a[href=?]", collavre.onboarding_replay_path, count: 0
      end
    end
  end
end
