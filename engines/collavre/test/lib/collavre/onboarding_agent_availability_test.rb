require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class OnboardingAgentAvailabilityTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup do
      @user = create_notice_user
      Current.user = @user
      @mission = NoticeRegistry.find(:onboarding_call_agent)
    end

    teardown { Current.reset }

    test "another searchable agent does not replace Kollavy" do
      users(:ai_bot).update!(searchable: true)
      Creative.create!(user: @user, description: "Plan")
      refute @mission.visible_to?(@user)
      assert_equal 2, Notices::Feed.new(@user).items.first[:steps].size
    end

    test "seeding Kollavy reveals the mission without an owned content creative" do
      refute @mission.visible_to?(@user)
      agent = Kollavy.seed!
      assert @mission.visible_to?(@user)
      assert_equal 3, Notices::Feed.new(@user).items.first[:steps].size
      refute @mission.visible_to?(agent)
    end

    test "revoking feedback hides the mission and restoring it reveals it" do
      agent = Kollavy.seed!
      share = CreativeShare.find_by!(creative: @user.inbox_creative, user: agent)
      share.update!(permission: :read)
      refute @mission.visible_to?(@user)
      share.update!(permission: :feedback)
      assert @mission.visible_to?(@user)
      share.destroy!
      refute @mission.visible_to?(@user)
    end

    test "an archived Inbox or disabled Kollavy is unavailable" do
      agent = Kollavy.seed!
      inbox = @user.inbox_creative
      inbox.update!(archived_at: Time.current)
      refute @mission.visible_to?(@user)
      inbox.update!(archived_at: nil)
      agent.update!(llm_vendor: nil)
      refute @mission.visible_to?(@user)
    end

    test "Main is explicit even when another topic was last visited" do
      Kollavy.seed!
      inbox = @user.inbox_creative
      other = inbox.topics.create!(name: "Other", user: @user)
      UserCreativePreference.create!(user: @user, creative: inbox, last_topic_id: other.id)
      routes = Collavre::Engine.routes.url_helpers
      assert_equal routes.creative_path(inbox, open_comments: true, topic_id: inbox.main_topic.id),
                   @mission.cta_path(routes, @user)
    end

    test "completion copy remains available when Kollavy is absent" do
      assert Notices::Feed.new(@user).completion(:onboarding_call_agent)[:done].present?
    end

    test "both locales use the current agent name in the guide and mention" do
      agent = Kollavy.seed!
      %i[onboarding_first_creative onboarding_sub_creative].each do |key|
        UserNotice.seed!(@user, key, :completed)
      end
      [ "Kollavy", "Renamed Helper" ].each do |name|
        agent.update!(name: name)
        %i[en ko].each do |locale|
          I18n.with_locale(locale) do
            copy = Notices::Feed.new(@user).items.find { |item| item[:key] == "onboarding_call_agent" }
            assert_includes copy[:body], "Inbox#Main"
            %i[title body cta].each { |field| assert_includes copy[field], name }
            assert_includes copy[:tip], "@#{name}:"
            comment = Comment.new(creative: @user.inbox_creative, user: @user, content: "@#{name}: Help")
            assert_includes comment.mentioned_users, agent
          end
        end
      end
    end
  end
end
