require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  # Drives the real onboarding missions through the model callbacks that emit
  # their completion events.
  class OnboardingNoticesTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup do
      Kollavy.seed!
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

        Comment.create!(creative: @user.inbox_creative, user: @user, content: "@Kollavy: How do I use Collavre?")
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
        Current.reset # Each user action has its own request/history context.
        Current.user = owner
        shared = Creative.create!(user: owner, description: "Shared")
        Current.reset
        Current.user = @user

        Creative.create!(user: owner, parent: shared, description: "Their step")
      end

      assert_equal "completed", status(:onboarding_sub_creative)
      assert_predicate UserNotice.find_by!(user: owner, notice_key: "onboarding_sub_creative"), :pending?
    end

    test "explicit system and sync actors do not credit the owner" do
      [ :sync, :system ].each do |origin|
        [ nil, @user ].each do |current_user|
          Current.reset
          Current.user = current_user
          Creatives::History.track(actor: nil, origin: origin) do
            root = Creative.create!(user: @user, description: "Imported root")
            Creative.create!(parent: root, description: "Imported child")
          end
          assert_nil status(:onboarding_first_creative)
          assert_nil status(:onboarding_sub_creative)
        end
      end
    end

    test "creation event retains its actor after the history context ends" do
      creative = nil
      Creatives::History.track(actor: nil, origin: :sync) do
        creative = Creative.create!(user: @user, description: "Imported")
      end
      # Model the delayed after-commit callback of an enclosing transaction.
      Current.reset
      Current.user = @user
      creative.send(:instrument_created_event)
      assert_nil status(:onboarding_first_creative)

      actor = create_notice_user("Collaborator")
      Current.reset
      Creatives::History.track(actor: actor, origin: :editor) do
        creative = Creative.create!(user: @user, description: "Contribution")
      end
      Current.reset
      assert_equal actor, creative.send(:creation_event_actor)
    end

    test "an early agent invocation completes without waiting for its reply" do
      agent = users(:ai_bot)
      agent.update!(searchable: true)
      Turbo::StreamsChannel.stub(:broadcast_replace_to, nil) do
        root = Creative.create!(user: @user, description: "Plan")
        Comment.create!(creative: root, user: @user, content: "@#{agent.name}: summarize")
        assert_equal "completed", status(:onboarding_call_agent)

        Creative.create!(user: @user, parent: root, description: "Step")
        assert_equal "completed", status(:onboarding_call_agent)
        assert_empty feed_keys
      end
    end

    test "replay remembers an early agent call but never reuses a previous replay" do
      agent = users(:ai_bot)
      agent.update!(searchable: true)
      broadcasts = []
      Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*, **options) { broadcasts << options[:locals] if options[:target] == Notices::Tracker::PAYLOAD_TARGET }) do
        root = Creative.create!(user: @user, description: "Existing plan")
        Comment.create!(creative: root, user: @user, content: "@#{agent.name}: old call")
        Notices::OnboardingReplay.call(@user)
        assert_equal "pending", status(:onboarding_call_agent)
        assert_equal %w[onboarding_first_creative], feed_keys

        broadcasts.clear
        Comment.create!(creative: root, user: @user, content: "@#{agent.name}: replay call")
        assert_equal "completed", status(:onboarding_call_agent)
        assert_nil broadcasts.sole[:completion], "an early call must not celebrate ahead of the current step"
        assert_equal %w[onboarding_first_creative], feed_keys
        Creative.create!(user: @user, description: "New plan")
        Creative.create!(user: @user, parent: root, description: "New step")
        assert_empty feed_keys

        Notices::OnboardingReplay.call(@user)
        Creative.create!(user: @user, parent: root, description: "Another replay")
        assert_equal "pending", status(:onboarding_call_agent)
        assert_equal %w[onboarding_call_agent], feed_keys
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
      assert_equal OnboardingNotices.agent_chat_path(routes, @user), mission.cta_path(routes, @user)

      root = Creative.create!(user: @user, description: "Plan")
      assert_equal OnboardingNotices.agent_chat_path(routes, @user), mission.cta_path(routes, @user)
      assert_equal routes.creative_path(root), NoticeRegistry.find(:onboarding_sub_creative).cta_path(routes, @user)
    end

    test "later steps point at the user's latest top-level creative" do
      routes = Collavre::Engine.routes.url_helpers
      assert_equal routes.creatives_path, OnboardingNotices.latest_creative_path(routes, @user)

      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      assert_equal routes.creative_path(root), OnboardingNotices.latest_creative_path(routes, @user)
    end

    test "agent chat stays in the Inbox regardless of owned or visited creatives" do
      routes = Collavre::Engine.routes.url_helpers
      mission = NoticeRegistry.find(:onboarding_call_agent)
      shared = Creative.create!(user: create_notice_user("Owner"), description: "Team plan")
      CreativeShare.create!(creative: shared, user: @user, permission: :feedback)
      @user.update!(last_visited_creative: shared)

      assert_equal OnboardingNotices.agent_chat_path(routes, @user), mission.cta_path(routes, @user)

      Creative.create!(user: @user, description: "Mine")
      assert_equal OnboardingNotices.agent_chat_path(routes, @user), mission.cta_path(routes, @user)
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
