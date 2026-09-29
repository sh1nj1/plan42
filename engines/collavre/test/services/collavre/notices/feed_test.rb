require "test_helper"
require_relative "../../../support/notice_test_helpers"

module Collavre
  module Notices
    class FeedTest < ActiveSupport::TestCase
      include NoticeTestHelpers

      setup do
        isolate_notice_registry
        @user = users(:two)
        @done = {}
        done = @done
        %i[tour_one tour_two].each do |key|
          NoticeRegistry.register(key, kind: :mission, group: :tour, icon: "🌱", target: ".btn",
                                       cta_path: ->(routes, _user) { routes.creatives_path },
                                       done_when: ->(_user) { done[key] })
        end
        NoticeRegistry.register(:release_note, kind: :feature, icon: "✨")
        NoticeRegistry.register(:outage, kind: :urgent)
      end

      teardown { restore_notice_registry }

      def keys(user = @user)
        Feed.new(user).items.map { |item| item[:key] }
      end

      test "hidden states skip audience evaluation" do
        %i[completed dismissed snoozed].each do |status|
          NoticeRegistry.register(status, audience: ->(_) { flunk "hidden audience evaluated" })
          UserNotice.record!(@user, status, status, snoozed_until: 1.hour.from_now)
        end
        assert_equal %w[outage tour_one release_note], keys
      end

      test "audience results including false are reused only within a feed" do
        calls = Hash.new(0)
        available = false
        %i[tour_one tour_two].each do |key|
          NoticeRegistry.register(key, kind: :mission, group: :tour, done_when: ->(_) { false },
                                       audience: ->(_) { calls[key] += 1; key == :tour_one || available })
        end
        feed = Feed.new(@user)
        assert_equal 1, feed.items.find { |item| item[:key] == "tour_one" }[:steps].size
        feed.completion(:tour_one)
        feed.items
        assert_equal({ tour_one: 1, tour_two: 1 }, calls)

        available = true
        assert_equal 2, Feed.new(@user).items.find { |item| item[:key] == "tour_one" }[:steps].size
        assert_equal({ tour_one: 2, tour_two: 2 }, calls)
      end

      test "skips audience-ineligible predecessors without seeding their state" do
        NoticeRegistry.register(:tour_one, kind: :mission, group: :tour,
                                audience: ->(user) { user != @user }, done_when: ->(_) { false })

        item = Feed.new(@user).items.find { |notice| notice[:key] == "tour_two" }
        assert_not_nil item
        assert_equal [ "current" ], item[:steps].map { |step| step[:state] }
        assert_nil UserNotice.find_by(user: @user, notice_key: "tour_one")
        assert_equal %w[outage tour_one release_note], keys(users(:one))
      end

      test "backfills an eligible mission after an audience-ineligible predecessor" do
        NoticeRegistry.register(:tour_one, kind: :mission, group: :tour, audience: ->(_) { false }, done_when: ->(_) { false })
        @done[:tour_two] = true

        assert_equal %w[outage release_note], keys
        assert UserNotice.find_by!(user: @user, notice_key: "tour_two").completed?
        assert_nil UserNotice.find_by(user: @user, notice_key: "tour_one")
      end

      test "orders by priority then registration and shows one mission per group" do
        assert_equal %w[outage tour_one release_note], keys
      end

      test "returns nothing without a user or for agents" do
        assert_empty Feed.new(nil).items
        assert_empty Feed.new(users(:ai_bot)).items
      end

      test "backfills a mission once and advances past it" do
        @done[:tour_one] = true

        assert_equal %w[outage tour_two release_note], keys
        assert UserNotice.find_by(user: @user, notice_key: "tour_one").completed?
        assert UserNotice.find_by(user: @user, notice_key: "tour_two").pending?

        @done[:tour_two] = true
        assert_includes keys, "tour_two", "done_when must not be re-evaluated once a row exists"
      end

      test "a completion recorded during the first render survives the backfill" do
        NoticeRegistry.register(:racing, kind: :mission, group: :race, done_when: lambda { |user|
          UserNotice.record!(user, :racing, :completed)
          false
        })

        assert_not_includes Feed.new(@user).items.map { |item| item[:key] }, "racing"
        assert UserNotice.find_by!(user: @user, notice_key: "racing").completed?
      end

      test "hides dismissed, completed, snoozed and out-of-window notices" do
        UserNotice.record!(@user, :outage, :dismissed)
        UserNotice.record!(@user, :release_note, :completed)
        UserNotice.record!(@user, :tour_one, :snoozed, snoozed_until: 1.hour.from_now)
        NoticeRegistry.register(:later, starts_at: 1.day.from_now)

        assert_empty keys, "a snoozed mission also blocks the rest of its group"

        UserNotice.record!(@user, :tour_one, :snoozed, snoozed_until: 1.minute.ago)
        assert_equal %w[tour_one], keys
      end

      test "serializes translated copy, tag, steps and call to action" do
        UserNotice.record!(@user, :tour_one, :completed)
        I18n.backend.store_translations(:en, collavre: { notices: { groups: { tour: "Tour %{step}/%{total}" },
          items: { tour_two: { title: "Second", summary: "S", body: "B", cta: "Go", tip: "Here", done: "Yay" },
                   tour_one: { title: "First" } } } })

        item = I18n.with_locale(:en) { Feed.new(@user).items.find { |i| i[:key] == "tour_two" } }

        assert_equal "Tour 2/2", item[:tag]
        assert_equal %w[Second S B Go Here Yay], item.values_at(:title, :summary, :body, :cta, :tip, :done)
        assert_equal "/creatives", item[:cta_url]
        assert_equal ".btn", item[:target]
        assert_equal [ { title: "First", state: "done" }, { title: "Second", state: "current" } ], item[:steps]

        feature = I18n.with_locale(:en) { Feed.new(@user).items.find { |i| i[:key] == "release_note" } }
        assert_equal I18n.t("collavre.notices.kinds.feature", locale: :en), feature[:tag]
        assert_equal I18n.t("collavre.notices.bar.ok", locale: :en), feature[:cta]
        assert_not feature.key?(:steps)
      end

      test "completion describes the celebration and the next step" do
        UserNotice.record!(@user, :tour_one, :completed)
        feed = Feed.new(@user)

        assert_equal({ key: "tour_one", done: I18n.t("collavre.notices.bar.completed"), next_key: "tour_two" }, feed.completion(:tour_one))
        assert_nil feed.completion(:missing)

        UserNotice.record!(@user, :tour_two, :completed)
        assert_nil Feed.new(@user).completion(:tour_two)[:next_key]
      end
    end
  end
end
