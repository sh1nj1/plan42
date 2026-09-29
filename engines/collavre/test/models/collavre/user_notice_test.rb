require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class UserNoticeTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    test "record! upserts one row per user and key" do
      user = users(:two)

      first = UserNotice.record!(user, :tour, :snoozed, snoozed_until: 1.day.from_now)
      second = UserNotice.record!(user, "tour", :completed)

      assert_equal first.id, second.id
      assert second.completed?
      assert_nil second.snoozed_until
      assert_not_nil second.completed_at
      assert_equal 1, UserNotice.where(user: user).count
    end

    test "record! inserts the first row with every attribute" do
      user = users(:two)
      until_time = 1.day.from_now.change(usec: 0)

      notice = UserNotice.record!(user, :fresh, :snoozed, snoozed_until: until_time)

      assert notice.snoozed?
      assert_equal until_time, notice.snoozed_until
      assert_nil notice.completed_at
    end

    test "record! cannot overwrite a completion committed after the caller read the row" do
      user = users(:two)
      UserNotice.record!(user, :tour, :pending)
      stale = UserNotice.find_by!(user: user, notice_key: "tour")
      UserNotice.where(id: stale.id).update_all(status: "completed", completed_at: Time.current)

      result = UserNotice.stub(:seed!, stale) do
        UserNotice.record!(user, :tour, :snoozed, snoozed_until: 1.day.from_now)
      end

      assert result.completed?
      assert_nil result.snoozed_until
    end

    test "record! keeps a completion over a stale snooze or dismissal" do
      user = users(:two)
      UserNotice.record!(user, :tour, :completed)

      assert UserNotice.record!(user, :tour, :snoozed, snoozed_until: 1.day.from_now).completed?
      assert UserNotice.record!(user, :tour, :dismissed).completed?
      assert UserNotice.find_by(user: user, notice_key: "tour").completed?
    end

    test "seed! writes the first state and never overwrites an existing row" do
      user = users(:two)

      seeded = UserNotice.seed!(user, :fresh, :completed)
      assert seeded.completed?
      assert_not_nil seeded.completed_at

      UserNotice.record!(user, :taken, :completed)
      assert UserNotice.seed!(user, :taken, :pending).completed?
      assert_nil UserNotice.seed!(user, :open, :pending).completed_at
    end

    test "hidden? covers finished rows and live snoozes only" do
      now = Time.current
      notice = UserNotice.new(user: users(:two), notice_key: "tour")

      assert_not notice.tap { |n| n.status = :pending }.hidden?(now)
      assert notice.tap { |n| n.status = :dismissed }.hidden?(now)
      assert notice.tap { |n| n.status = :completed }.hidden?(now)
      notice.status = :snoozed
      notice.snoozed_until = now + 1.hour
      assert notice.hidden?(now)
      notice.snoozed_until = now - 1.hour
      assert_not notice.hidden?(now)
    end

    test "is removed with its user" do
      user = create_notice_user
      UserNotice.record!(user, :tour, :pending)

      assert_difference -> { UserNotice.count }, -1 do
        user.destroy!
      end
    end
  end
end
