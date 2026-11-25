require "test_helper"
require_relative "../../../support/notice_test_helpers"

module Collavre
  module Notices
    class RefreshDeadlineTest < ActiveSupport::TestCase
      include NoticeTestHelpers

      setup do
        isolate_notice_registry
        @user = users(:two)
      end

      teardown { restore_notice_registry }

      test "chooses the earliest future boundary including snooze deadlines" do
        freeze_time do
          now = Time.current
          NoticeRegistry.register(:window, starts_at: now + 1.hour, ends_at: now + 3.hours)
          NoticeRegistry.register(:ending, ends_at: now + 2.hours)
          UserNotice.record!(@user, :tour, :snoozed, snoozed_until: now + 30.minutes)

          [ 30.minutes, 1.hour, 2.hours, 3.hours ].each do |offset|
            assert_equal now + offset, RefreshDeadline.for(@user)
            travel_to now + offset
          end
          assert_nil RefreshDeadline.for(@user)
        end
      end

      test "ignores past boundaries and non-snoozed rows" do
        freeze_time do
          NoticeRegistry.register(:expired, starts_at: 2.hours.ago, ends_at: Time.current)
          UserNotice.record!(@user, :expired_snooze, :snoozed, snoozed_until: 1.minute.ago)
          UserNotice.record!(@user, :finished, :completed)
          assert_nil RefreshDeadline.for(@user)
        end
      end

      test "has no deadline for signed out visitors" do
        NoticeRegistry.register(:future, starts_at: 1.hour.from_now)
        assert_nil RefreshDeadline.for(nil)
      end
    end
  end
end
