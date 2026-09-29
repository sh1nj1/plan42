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

    test "refresh and mutation broadcasts preserve a non-root engine mount" do
      Rails.application.routes.draw { mount Collavre::Engine => "/collavre" }
      NoticeRegistry.register(:mounted_cta, cta_path: ->(routes, user) { routes.creative_path(user.id, open_comments: true) })
      expected = "/collavre/creatives/#{@user.id}?open_comments=true"

      get "/collavre/user_notices"
      assert_response :success
      assert_equal expected, response.parsed_body["items"].find { |item| item["key"] == "mounted_cta" }["cta_url"]

      broadcasts = []
      recorder = ->(*_args, **options) { broadcasts << options[:locals][:items] }
      Turbo::StreamsChannel.stub(:broadcast_replace_to, recorder) do
        post "/collavre/user_notices/release_note/dismiss"
        assert_response :no_content
      end
      assert_equal expected, broadcasts.sole.find { |item| item[:key] == "mounted_cta" }[:cta_url]
    ensure
      Rails.application.reload_routes!
    end

    test "successful mutations broadcast authoritative feeds to every subscribed tab" do
      freeze_time do
        [ [ "tour_one", "snooze", false ], [ "tour_one", "restore", true ],
          [ "release_note", "dismiss", false ], [ "release_note", "restore", true ],
          [ "release_note", "complete", false ] ].each do |key, action, visible|
          broadcasts = []
          recorder = ->(*args, **options) { broadcasts << [ args, options ] }
          Turbo::StreamsChannel.stub(:broadcast_replace_to, recorder) do
            post "/user_notices/#{key}/#{action}"
          end
          assert_response :no_content
          args, options = broadcasts.sole
          assert_equal [ [ "inbox", @user ] ], args
          assert_equal Notices::Tracker::PAYLOAD_TARGET, options[:target]
          locals = options[:locals]
          assert_equal visible, locals[:items].any? { |item| item[:key] == key }
          assert_equal key, locals[:changed].to_s
          assert_nil locals[:completion], "mutations must not celebrate in other tabs"
          html = ApplicationController.render(partial: options[:partial], locals: locals)
          payload = Nokogiri::HTML.fragment(html).at_css("#notice-bar-payload")
          assert_equal key, payload["data-changed"]
          if action == "snooze"
            assert_equal 1.day.from_now.iso8601(3), payload["data-refresh-at"]
          else
            assert_nil payload["data-refresh-at"]
          end
        end
      end
    end

    test "rejected mutations do not broadcast" do
      reject_broadcast = ->(*) { flunk "rejected action broadcast a feed" }
      Turbo::StreamsChannel.stub(:broadcast_replace_to, reject_broadcast) do
        %w[tour_one/dismiss tour_one/complete release_note/snooze tour_one/restore].each do |action|
          post "/user_notices/#{action}"
          assert_response :unprocessable_entity
        end
        post "/user_notices/nope/dismiss"
        assert_response :not_found
        post "/user_notices/admins_only/dismiss"
        assert_response :not_found
      end
    end

    test "feed returns snooze deadline and restores only expired pending missions" do
      freeze_time do
        post "/user_notices/tour_one/snooze"
        assert_equal 1.day.from_now.iso8601(3), response.headers["X-Notice-Snoozed-Until"]
        get "/user_notices"
        assert_response :success
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_equal 1.day.from_now, Time.iso8601(response.parsed_body["refresh_at"])
        refute_includes response.parsed_body["items"].pluck("key"), "tour_one"

        travel 1.day
        get "/user_notices"
        assert_includes response.parsed_body["items"].pluck("key"), "tour_one"
        assert_nil response.parsed_body["refresh_at"]
        UserNotice.complete!(@user, :tour_one)
        get "/user_notices"
        refute_includes response.parsed_body["items"].pluck("key"), "tour_one"
      end
    end

    test "initial page and successive feeds schedule start and end boundaries" do
      freeze_time do
        starts_at = 1.hour.from_now
        ends_at = 2.hours.from_now
        NoticeRegistry.register(:scheduled, starts_at: starts_at, ends_at: ends_at)

        get "/creatives"
        assert_response :success
        assert_select "[data-notice-bar-refresh-at-value=?]", starts_at.iso8601(3)
        get "/user_notices"
        assert_equal starts_at, Time.iso8601(response.parsed_body["refresh_at"])
        refute_includes response.parsed_body["items"].pluck("key"), "scheduled"

        travel_to starts_at
        get "/user_notices"
        assert_equal ends_at, Time.iso8601(response.parsed_body["refresh_at"])
        assert_includes response.parsed_body["items"].pluck("key"), "scheduled"

        travel_to ends_at
        get "/user_notices"
        assert_nil response.parsed_body["refresh_at"]
        refute_includes response.parsed_body["items"].pluck("key"), "scheduled"
      end
    end

    test "mutation and event broadcasts retain upcoming window boundaries" do
      freeze_time do
        deadline = 1.hour.from_now
        NoticeRegistry.register(:scheduled, starts_at: deadline)
        broadcasts = []
        recorder = ->(*args, **options) { broadcasts << options[:locals] }
        Turbo::StreamsChannel.stub(:broadcast_replace_to, recorder) do
          post "/user_notices/tour_one/snooze"
          assert_response :no_content
          Notices::Tracker.broadcast(@user, completed: :release_note)
        end
        assert_equal 2, broadcasts.size
        broadcasts.each { |locals| assert_equal deadline, locals[:refresh_at] }
      end
    end

    test "a stale snooze from an open sheet does not reopen a completed mission" do
      UserNotice.record!(@user, :tour_one, :completed)
      post "/user_notices/tour_one/snooze"
      assert_response :no_content
      assert state("tour_one").completed?
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

    test "restore rejects a completion committed after it reads the snoozed row" do
      UserNotice.record!(@user, :tour_one, :snoozed, snoozed_until: 1.day.from_now)
      original = UserNotice.method(:record!)
      complete_before_restore = lambda do |user, key, status, **options|
        original.call(user, key, :completed)
        original.call(user, key, status, **options)
      end

      UserNotice.stub(:record!, complete_before_restore) do
        post "/user_notices/tour_one/restore"
      end

      assert_response :unprocessable_entity
      assert state("tour_one").completed?
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
      get "/user_notices"
      assert_response :redirect
    end
  end
end
