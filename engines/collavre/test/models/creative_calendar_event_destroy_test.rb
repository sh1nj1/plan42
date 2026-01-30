# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeCalendarEventDestroyTest < ActiveSupport::TestCase
    test "destroying a creative removes linked creatives with calendar events" do
      user = users(:one)
      origin = Creative.create!(user: user, description: "Origin", progress: 0.0)
      linked = Creative.create!(origin: origin, user: user)
      event = CalendarEvent.create!(
        user: user,
        creative: linked,
        google_event_id: SecureRandom.uuid,
        start_time: Time.current,
        end_time: 1.hour.from_now
      )

      assert_difference("Creative.count", -2) do
        assert_difference("CalendarEvent.count", -1) do
          origin.destroy
        end
      end

      assert_not Creative.exists?(linked.id)
      assert_not CalendarEvent.exists?(event.id)
    end
  end
end
