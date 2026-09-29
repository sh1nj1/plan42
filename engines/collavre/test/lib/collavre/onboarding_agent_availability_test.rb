require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class OnboardingAgentAvailabilityTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup do
      @user = create_notice_user
      Current.user = @user
      User.ai_agents.update_all(searchable: false)
      @mission = NoticeRegistry.find(:onboarding_call_agent)
    end

    teardown { Current.reset }

    test "a searchable agent needs an active commentable destination" do
      users(:ai_bot).update!(searchable: true)
      refute @mission.visible_to?(@user)

      root = Creative.create!(user: @user, description: "Archived", archived_at: Time.current)
      Creative.create!(parent: root, description: "Archived child", archived_at: Time.current)
      @user.update!(last_visited_creative: root)
      refute @mission.visible_to?(@user)
      assert_empty Notices::Feed.new(@user).items

      root.update!(archived_at: nil)
      assert @mission.visible_to?(@user)
    end

    test "a link to an archived original is not a commentable destination" do
      users(:ai_bot).update!(searchable: true)
      original = Creative.create!(user: create_notice_user, description: "Original", archived_at: Time.current)
      CreativeShare.create!(creative: original, user: @user, permission: :feedback)
      link = Creative.create!(user: @user, origin: original)
      @user.update!(last_visited_creative: link)

      refute @mission.visible_to?(@user)
      assert_nil OnboardingNotices.latest_creative(@user)
    end

    test "no agents means two steps and no pending agent mission" do
      User.ai_agents.update_all(llm_vendor: nil)
      item = Notices::Feed.new(@user).items.first
      assert_equal 2, item[:steps].size
      assert_equal I18n.t("collavre.notices.groups.onboarding", step: 1, total: 2), item[:tag]

      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      assert_empty Notices::Feed.new(@user).items
      assert_nil UserNotice.find_by(user: @user, notice_key: @mission.key)
      assert_nil Notices::Feed.new(@user).completion(:onboarding_sub_creative)[:next_key]
    end

    test "a newly available agent reveals the mission and revocation hides it" do
      root = Creative.create!(user: @user, description: "Plan")
      Creative.create!(user: @user, parent: root, description: "Step")
      refute @mission.visible_to?(@user)

      agent = users(:ai_bot)
      agent.update!(searchable: true)
      item = Notices::Feed.new(@user).items.sole
      assert_equal @mission.key.to_s, item[:key]
      assert_equal 3, item[:steps].size
      assert_equal "pending", UserNotice.find_by!(user: @user, notice_key: @mission.key).status
      refute @mission.visible_to?(agent)

      agent.update!(searchable: false)
      assert_empty Notices::Feed.new(@user).items
    end

    test "a private agent shared with the destination is available" do
      root = Creative.create!(user: @user, description: "Plan")
      refute @mission.visible_to?(@user)
      CreativeShare.create!(creative: root, user: users(:ai_bot), permission: :feedback)
      assert @mission.visible_to?(@user)
    end

    test "an agent shared elsewhere does not make the destination usable" do
      other = Creative.create!(user: create_notice_user, description: "Other")
      CreativeShare.create!(creative: other, user: users(:ai_bot), permission: :feedback)
      Creative.create!(user: @user, description: "Plan")
      refute @mission.visible_to?(@user)
    end

    test "availability uses the shared destination for a collaborator" do
      shared = Creative.create!(user: create_notice_user, description: "Shared")
      CreativeShare.create!(creative: shared, user: @user, permission: :feedback)
      CreativeShare.create!(creative: shared, user: users(:ai_bot), permission: :feedback)
      @user.update!(last_visited_creative: shared)
      assert @mission.visible_to?(@user)
    end
  end
end
