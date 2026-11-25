require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class OnboardingDestinationsTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup do
      @user = create_notice_user
      Current.user = @user
      @routes = Collavre::Engine.routes.url_helpers
    end

    teardown { Current.reset }

    test "the sub-creative mission skips the newest archived root" do
      active = Creative.create!(user: @user, description: "Active")
      Creative.create!(user: @user, description: "Archived", archived_at: Time.current)

      assert_destinations active
    end

    test "archived owned roots fall back to an active shared last visit" do
      Creative.create!(user: @user, description: "Archived", archived_at: Time.current)
      shared = Creative.create!(user: create_notice_user, description: "Shared")
      CreativeShare.create!(creative: shared, user: @user, permission: :feedback)
      @user.update!(last_visited_creative: shared)

      assert_destinations shared
    end

    test "an archived shared last visit is excluded despite comment permission" do
      shared = Creative.create!(user: create_notice_user, description: "Archived", archived_at: Time.current)
      CreativeShare.create!(creative: shared, user: @user, permission: :feedback)
      @user.update!(last_visited_creative: shared)

      assert_destinations nil
    end

    test "an archived owned last visit is excluded but still counts as past creation" do
      root = Creative.create!(user: @user, description: "Archived", archived_at: Time.current)
      @user.update!(last_visited_creative: root)

      assert_destinations nil
      assert OnboardingNotices.creative_created?(@user)
    end

    private

    def assert_destinations(creative)
      expected = creative ? @routes.creative_path(creative) : @routes.creatives_path
      assert_equal expected, NoticeRegistry.find(:onboarding_sub_creative).cta_path(@routes, @user)
      inbox = @user.inbox_creative
      assert_equal @routes.creative_path(inbox, open_comments: true, topic_id: inbox.main_topic.id),
                   NoticeRegistry.find(:onboarding_call_agent).cta_path(@routes, @user)
    end
  end
end
