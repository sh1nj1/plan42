require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  # Drives the real onboarding missions through the model callbacks that emit
  # their completion events.
  class OnboardingNoticesTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup do
      @user = create_notice_user
      Current.user = @user
    end

    teardown { Current.reset }

    def status(key)
      UserNotice.find_by(user: @user, notice_key: key.to_s)&.status
    end

    def feed_keys
      Notices::Feed.new(@user).items.map { |item| item[:key] }
    end

    test "a new user walks the three missions in order" do
      Turbo::StreamsChannel.stub(:broadcast_replace_to, nil) do
        assert_equal %w[onboarding_first_creative], feed_keys

        root = Creative.create!(user: @user, description: "Plan")
        assert_equal "completed", status(:onboarding_first_creative)
        assert_equal %w[onboarding_sub_creative], feed_keys

        Creative.create!(user: @user, parent: root, description: "Step")
        assert_equal "completed", status(:onboarding_sub_creative)

        agent = users(:ai_bot)
        agent.update!(searchable: true)
        Comment.create!(creative: root, user: @user, content: "@#{agent.name}: summarize")
        assert_equal "completed", status(:onboarding_call_agent)
        assert_empty feed_keys
      end
    end

    test "an inbox does not count as a first creative and plain comments do not call an agent" do
      Turbo::StreamsChannel.stub(:broadcast_replace_to, nil) do
        Creative.inbox_for(@user)
        assert_nil status(:onboarding_first_creative)
        assert_equal %w[onboarding_first_creative], feed_keys

        root = Creative.create!(user: @user, description: "Plan")
        Creative.create!(user: @user, parent: root, description: "Step")
        Comment.create!(creative: root, user: @user, content: "just a note")
        assert_equal "pending", status(:onboarding_call_agent)
      end
    end

    test "existing users are backfilled past what they already did" do
      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      UserNotice.where(user: @user).delete_all
      Comment.create!(creative: root, user: users(:ai_bot), content: "Done")

      assert_empty feed_keys
      assert_equal %w[completed completed completed],
                   %i[onboarding_first_creative onboarding_sub_creative onboarding_call_agent].map { |key| status(key) }
    end

    test "later steps point at the user's latest top-level creative" do
      routes = Collavre::Engine.routes.url_helpers
      assert_equal routes.creatives_path, OnboardingNotices.latest_creative_path(routes, @user)

      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      assert_equal routes.creative_path(root), OnboardingNotices.latest_creative_path(routes, @user)
    end
  end
end
