require "test_helper"
require_relative "../../../support/notice_test_helpers"

module Collavre
  module Notices
    class TrackerTest < ActiveSupport::TestCase
      include NoticeTestHelpers

      EVENT = "thing_done.collavre".freeze

      setup do
        isolate_notice_registry
        @user = users(:two)
        { tour_one: :one, tour_two: :two }.each do |key, flag|
          NoticeRegistry.register(key, kind: :mission, group: :tour, completes_on: { EVENT => ->(payload) { payload[flag] } })
        end
        @broadcasts = []
      end

      teardown { restore_notice_registry }

      def capture_broadcasts(&block)
        recorder = ->(*args, **kwargs) { @broadcasts << [ args, kwargs ] }
        Turbo::StreamsChannel.stub(:broadcast_replace_to, recorder, &block)
      end

      def status(key)
        UserNotice.find_by(user: @user, notice_key: key.to_s)&.status
      end

      test "finished candidates skip audience checks while snoozed candidates remain eligible" do
        %i[completed dismissed].each do |status|
          NoticeRegistry.register(status, audience: ->(_) { flunk "finished audience evaluated" },
                                           completes_on: { EVENT => true })
          UserNotice.record!(@user, status, status)
        end
        UserNotice.record!(@user, :tour_one, :snoozed, snoozed_until: 1.hour.from_now)
        assert_equal %i[tour_one tour_two], Tracker.open_candidates(EVENT, @user).map(&:key)
      end

      test "completes the head mission and broadcasts the refreshed bar" do
        capture_broadcasts { ActiveSupport::Notifications.instrument(EVENT, user: @user, one: true) }

        assert_equal "completed", status(:tour_one)
        assert_nil status(:tour_two), "the event that is still evaluating tour_two leaves its backfill for later"
        args, kwargs = @broadcasts.sole
        assert_equal [ [ "inbox", @user ] ], args
        assert_equal Tracker::PAYLOAD_TARGET, kwargs[:target]
        assert_equal "tour_two", kwargs[:locals][:completion][:next_key]
        assert_equal %w[tour_two], kwargs[:locals][:items].map { |item| item[:key] }
      end

      test "ignores agents, unmatched payloads, finished notices and other events" do
        capture_broadcasts do
          Tracker.handle(EVENT, user: users(:ai_bot), one: true)
          Tracker.handle(EVENT, user: nil, one: true)
          Tracker.handle(EVENT, user: @user, one: false)
          Tracker.handle("other.collavre", user: @user, one: true)
          Tracker.handle(EVENT, user: @user, two: true)
        end
        assert_nil status(:tour_one)
        assert_nil status(:tour_two), "a later mission cannot finish before its head"

        UserNotice.record!(@user, :tour_one, :dismissed)
        capture_broadcasts { Tracker.handle(EVENT, user: @user, one: true, two: true) }
        assert_equal "dismissed", status(:tour_one)
        assert_nil status(:tour_two)
        assert_empty @broadcasts
      end

      test "advances through a group one event at a time" do
        capture_broadcasts do
          Tracker.handle(EVENT, user: @user, one: true)
          Tracker.handle(EVENT, user: @user, two: true)
        end

        assert_equal "completed", status(:tour_two)
        assert_nil @broadcasts.last.last[:locals][:completion][:next_key]
      end

      # Creating a sub-item before the first mission finishes both at once; each
      # completion is broadcast so the bar can celebrate them in turn.
      test "cascades when one event satisfies consecutive missions" do
        capture_broadcasts { Tracker.handle(EVENT, user: @user, one: true, two: true) }

        assert_equal %w[completed completed], [ status(:tour_one), status(:tour_two) ]
        assert_equal %w[tour_one tour_two], @broadcasts.map { |_, kwargs| kwargs[:locals][:completion][:key] }
      end

      # The first broadcast must not backfill the mission the same event is
      # about to complete, or the bar would skip straight to "all done".
      test "cascade keeps the intermediate step when later missions are already done" do
        NoticeRegistry.register(:tour_two, kind: :mission, group: :tour, done_when: ->(_) { true },
                                           completes_on: { EVENT => ->(payload) { payload[:two] } })
        UserNotice.record!(@user, :tour_one, :pending)
        capture_broadcasts { Tracker.handle(EVENT, user: @user, one: true, two: true) }

        first, second = @broadcasts.map { |_, kwargs| kwargs[:locals] }
        assert_equal "tour_two", first[:completion][:next_key]
        assert_equal %w[tour_two], first[:items].map { |item| item[:key] }
        assert_equal [ "tour_two", nil ], [ second[:completion][:key], second[:completion][:next_key] ]
      end

      test "renders the broadcast in the user's locale" do
        @user.update!(locale: "ko")
        locales = []
        Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*, **) { locales << I18n.locale }) do
          Tracker.broadcast(@user)
        end
        assert_equal [ :ko ], locales

        @user.update!(locale: "xx")
        assert_equal I18n.default_locale, Tracker.locale_for(@user)
      end

      test "never raises into the code that emitted the event" do
        NoticeRegistry.register(:broken, kind: :feature, completes_on: { EVENT => ->(_payload) { raise "boom" } })

        assert_nothing_raised { Tracker.handle(EVENT, user: @user, one: false) }
      end
    end
  end
end
