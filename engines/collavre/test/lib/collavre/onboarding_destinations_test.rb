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

    test "both later missions skip the newest archived root" do
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
      { onboarding_sub_creative: {}, onboarding_call_agent: { open_comments: true } }.each do |key, options|
        expected = creative ? @routes.creative_path(creative, **options) : @routes.creatives_path
        assert_equal expected, NoticeRegistry.find(key).cta_path(@routes, @user)
      end
    end
  end
end
