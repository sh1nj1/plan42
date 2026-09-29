require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class NoticeRegistryTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup { isolate_notice_registry }
    teardown { restore_notice_registry }

    def mission(key, **extra)
      NoticeRegistry.register(key, kind: :mission, group: :tour, done_when: ->(_user) { false }, **extra)
    end

    test "registers, finds and unregisters notices in registration order" do
      first = mission(:tour_one)
      second = NoticeRegistry.register(:release_note, kind: :feature)

      assert_equal [ first, second ], NoticeRegistry.all
      assert_equal second, NoticeRegistry.find("release_note")
      assert_nil NoticeRegistry.find(nil)
      assert_equal [ first ], NoticeRegistry.group(:tour)

      NoticeRegistry.unregister(:release_note)
      assert_nil NoticeRegistry.find(:release_note)
    end

    test "defaults kind to announcement and priority by kind" do
      assert_equal :announcement, NoticeRegistry.register(:plain).kind
      assert_equal 2, NoticeRegistry.find(:plain).priority
      assert_equal 0, NoticeRegistry.register(:outage, kind: :urgent).priority
      assert_equal 1, mission(:tour_one).priority
      assert_equal 7, NoticeRegistry.register(:custom, kind: :feature, priority: 7).priority
    end

    test "rejects invalid definitions at registration" do
      assert_raises(ArgumentError) { NoticeRegistry.register(:"Bad-Key") }
      assert_raises(ArgumentError) { NoticeRegistry.register(:odd, kind: :popup) }
      assert_raises(ArgumentError) { NoticeRegistry.register(:loose, kind: :mission, done_when: ->(_u) { true }) }
      assert_raises(ArgumentError) { NoticeRegistry.register(:endless, kind: :mission, group: :tour) }
    end

    test "active? honours the schedule window" do
      now = Time.current
      notice = NoticeRegistry.register(:window, starts_at: now - 1.hour, ends_at: now + 1.hour)

      assert notice.active?(now)
      assert_not notice.active?(now - 2.hours)
      assert_not notice.active?(now + 1.hour)
    end

    test "audience defaults to humans and can be overridden" do
      notice = NoticeRegistry.register(:humans)
      admins = NoticeRegistry.register(:admins, audience: ->(user) { user.system_admin? })

      assert notice.visible_to?(users(:one))
      assert_not notice.visible_to?(users(:ai_bot))
      assert_not notice.visible_to?(nil)
      assert admins.visible_to?(users(:one))
      assert_not admins.visible_to?(users(:two))
    end

    test "completion rules accept true, a payload proc or fall back to done_when" do
      done = true
      notice = NoticeRegistry.register(:rules, kind: :feature, done_when: ->(_user) { done },
        completes_on: { "a.collavre" => true, "b.collavre" => ->(payload) { payload[:ok] }, "c.collavre" => :check })

      assert notice.listens_to?("a.collavre")
      assert_not notice.listens_to?("z.collavre")
      assert_equal [ notice ], NoticeRegistry.listening_to("b.collavre")
      assert notice.completed_by?("a.collavre", {}, users(:one))
      assert notice.completed_by?("b.collavre", { ok: true }, users(:one))
      assert_not notice.completed_by?("b.collavre", { ok: false }, users(:one))
      assert notice.completed_by?("c.collavre", {}, users(:one))
      done = false
      assert_not notice.completed_by?("c.collavre", {}, users(:one))
      assert_not NoticeRegistry.register(:no_rule).done_for?(users(:one))
    end

    test "cta_path accepts a string or a proc" do
      assert_equal "/x", NoticeRegistry.register(:fixed, cta_path: "/x").cta_path(nil, nil)
      dynamic = NoticeRegistry.register(:dynamic, cta_path: ->(routes, user) { "#{routes}/#{user}" })
      assert_equal "r/u", dynamic.cta_path("r", "u")
      assert_equal "collavre.notices.items.dynamic", dynamic.i18n_scope
    end

    test "install routes collavre events to the tracker and re-registers on reload" do
      subscriptions = []
      prepares = []
      handled = []
      ActiveSupport::Notifications.stub(:subscribe, ->(pattern, &block) { subscriptions << [ pattern, block ] }) do
        Rails.application.config.stub(:to_prepare, ->(&block) { prepares << block }) do
          NoticeRegistry.install
        end
      end

      pattern, listener = subscriptions.sole
      assert_match pattern, "creative_created.collavre"
      assert_no_match pattern, "sql.active_record"
      Notices::Tracker.stub(:handle, ->(name, payload) { handled << [ name, payload ] }) do
        listener.call(ActiveSupport::Notifications::Event.new("x.collavre", nil, nil, "id", { user: 1 }))
      end
      assert_equal [ [ "x.collavre", { user: 1 } ] ], handled

      NoticeRegistry.register(:stale)
      prepares.sole.call
      assert_nil NoticeRegistry.find(:stale)
      assert NoticeRegistry.find(:onboarding_first_creative)
    end
  end
end
