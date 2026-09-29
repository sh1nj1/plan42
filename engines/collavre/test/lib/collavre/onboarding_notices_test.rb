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
      users(:ai_bot).update!(searchable: true)
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

    test "a child added to someone else's tree counts for whoever added it" do
      owner = create_notice_user
      Turbo::StreamsChannel.stub(:broadcast_replace_to, nil) do
        Creative.create!(user: @user, description: "Mine")
        Current.user = owner
        shared = Creative.create!(user: owner, description: "Shared")
        Current.user = @user

        Creative.create!(user: owner, parent: shared, description: "Their step")
      end

      assert_equal "completed", status(:onboarding_sub_creative)
      assert_nil UserNotice.find_by(user: owner, notice_key: "onboarding_sub_creative")
    end

    test "an early agent invocation is backfilled without waiting for its reply" do
      agent = users(:ai_bot)
      agent.update!(searchable: true)
      Turbo::StreamsChannel.stub(:broadcast_replace_to, nil) do
        root = Creative.create!(user: @user, description: "Plan")
        Comment.create!(creative: root, user: @user, content: "@#{agent.name}: summarize")
        assert_nil status(:onboarding_call_agent)

        Creative.create!(user: @user, parent: root, description: "Step")
        assert_equal "completed", status(:onboarding_call_agent)
        assert_empty feed_keys
      end
    end

    test "backfill recognizes calls in shared creatives but not another user's calls" do
      agent = users(:ai_bot)
      agent.update!(searchable: true)
      shared = Creative.create!(user: create_notice_user, description: "Shared")
      Comment.create!(creative: shared, user: shared.user, content: "@#{agent.name}: summarize")
      refute NoticeRegistry.find(:onboarding_call_agent).done_for?(@user)

      Comment.create!(creative: shared, user: @user, content: "ordinary note")
      refute NoticeRegistry.find(:onboarding_call_agent).done_for?(@user)

      Comment.create!(creative: shared, user: @user, content: "@#{agent.name}: summarize")
      assert NoticeRegistry.find(:onboarding_call_agent).done_for?(@user)
    end

    test "existing users are backfilled past what they already did" do
      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      UserNotice.where(user: @user).delete_all
      agent = users(:ai_bot)
      agent.update!(searchable: true)
      Comment.create!(creative: root, user: @user, content: "@#{agent.name}: summarize")

      assert_empty feed_keys
      assert_equal %w[completed completed completed],
                   %i[onboarding_first_creative onboarding_sub_creative onboarding_call_agent].map { |key| status(key) }
    end

    test "agent mission opens the comments popup without changing the sub-creative destination" do
      routes = Collavre::Engine.routes.url_helpers
      mission = NoticeRegistry.find(:onboarding_call_agent)
      assert_equal routes.creatives_path, mission.cta_path(routes, @user)

      root = Creative.create!(user: @user, description: "Plan")
      assert_equal routes.creative_path(root, open_comments: true), mission.cta_path(routes, @user)
      assert_equal routes.creative_path(root), NoticeRegistry.find(:onboarding_sub_creative).cta_path(routes, @user)
    end

    test "later steps point at the user's latest top-level creative" do
      routes = Collavre::Engine.routes.url_helpers
      assert_equal routes.creatives_path, OnboardingNotices.latest_creative_path(routes, @user)

      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      assert_equal routes.creative_path(root), OnboardingNotices.latest_creative_path(routes, @user)
    end

    test "a collaborator without their own tree is sent to the shared creative they visited last" do
      routes = Collavre::Engine.routes.url_helpers
      mission = NoticeRegistry.find(:onboarding_call_agent)
      shared = Creative.create!(user: create_notice_user("Owner"), description: "Team plan")
      CreativeShare.create!(creative: shared, user: @user, permission: :feedback)
      @user.update!(last_visited_creative: shared)

      assert_equal routes.creative_path(shared, open_comments: true), mission.cta_path(routes, @user)

      own = Creative.create!(user: @user, description: "Mine")
      assert_equal routes.creative_path(own, open_comments: true), mission.cta_path(routes, @user)
    end

    test "a last visit the user cannot comment on is not a destination" do
      routes = Collavre::Engine.routes.url_helpers
      shared = Creative.create!(user: create_notice_user("Owner"), description: "Read only")
      CreativeShare.create!(creative: shared, user: @user, permission: :read)
      @user.update!(last_visited_creative: shared)

      assert_equal routes.creatives_path, OnboardingNotices.latest_creative_path(routes, @user)
    end
  end
end
