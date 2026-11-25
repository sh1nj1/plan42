require "test_helper"
require_relative "../../support/notice_test_helpers"

module Collavre
  class OnboardingCreationBackfillTest < ActiveSupport::TestCase
    include NoticeTestHelpers

    setup do
      @user = create_notice_user
      @owner = create_notice_user("Owner")
      @shared = Creative.create!(user: @owner, description: "Shared")
      CreativeShare.create!(creative: @shared, user: @user, permission: :write)
      Current.user = @user
    end

    teardown { Current.reset }

    test "linked placements never count with or without human creation history" do
      link = @shared.create_linked_creative_for_user(@user)
      assert_not OnboardingNotices.content_creation?(link)
      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)
      UserNotice.where(user: @user).delete_all
      assert_equal "onboarding_first_creative", Notices::Feed.new(@user).items.first[:key]

      Creatives::History.track(actor: @user, origin: :editor) do
        Creative.create!(user: @user, origin: @shared, parent: link, description: "Linked child")
      end
      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)
      assert UserNotice.find_by!(user: @user, notice_key: :onboarding_first_creative).pending?
    end

    def create_shared_child(actor: @user)
      Creatives::History.track(actor: actor, origin: :editor) do
        Creative.create!(parent: @shared, description: "Contribution")
      end
    end

    def done?(key)
      NoticeRegistry.find(key).done_for?(@user)
    end

    test "shared-tree creation history backfills both missions for the actor" do
      child = create_shared_child
      assert_equal @owner.id, child.user_id
      assert CreativeChange.joins(:change_set).where(creative: child, operation: "create",
        creative_change_sets: { user_id: @user.id, status: "applied" }).exists?
      UserNotice.where(user: @user).delete_all

      Notices::Feed.new(@user).items

      %w[onboarding_first_creative onboarding_sub_creative].each do |key|
        assert UserNotice.find_by!(user: @user, notice_key: key).completed?
      end
    end

    test "inherited ownership does not credit the owner for a collaborator's child" do
      create_shared_child
      UserNotice.where(user: @owner).delete_all

      Notices::Feed.new(@owner).items

      assert UserNotice.find_by!(user: @owner, notice_key: :onboarding_first_creative).completed?
      assert UserNotice.find_by!(user: @owner, notice_key: :onboarding_sub_creative).pending?
    end

    test "owned creations with actor history cannot use the legacy fallback" do
      child = create_shared_child
      child.update_columns(user_id: @user.id)
      change_set = child.creative_changes.find_by!(operation: "create").change_set

      change_set.update!(user_id: @owner.id)
      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)

      change_set.update!(user_id: @user.id, actor_kind: "system")
      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)

      change_set.update!(actor_kind: "human", status: "reverted")
      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)
    end

    test "owned children without creation history retain legacy completion" do
      root = Creative.create!(user: @user, description: "Legacy root")
      Creative.create!(parent: root, description: "Legacy child")

      assert done?(:onboarding_first_creative)
      assert done?(:onboarding_sub_creative)
    end

    test "pruned collaborator creation cannot fall back to inherited ownership" do
      child = nil
      travel_to 200.days.ago do
        child = create_shared_child
      end
      Creatives::History.track(actor: @owner, origin: :editor) { child.update!(description: "Updated") }
      SystemSetting.stub(:creative_history_retention_count, 1) do
        SystemSetting.stub(:creative_history_retention_days, 7) { CreativeHistoryPruneJob.perform_now }
      end
      assert_not child.creative_changes.where(operation: "create").exists?
      assert_operator child.reload.revision, :>, 0
      UserNotice.where(user: @owner).delete_all

      Notices::Feed.new(@owner).items

      assert UserNotice.find_by!(user: @owner, notice_key: :onboarding_sub_creative).pending?
    end

    test "pruned sync history cannot become legacy owner activity" do
      creative = nil
      travel_to 200.days.ago do
        Creatives::History.track(actor: nil, origin: :sync) do
          creative = Creative.create!(user: @user, description: "Imported")
        end
      end
      CreativeHistoryPruneJob.perform_now
      assert_empty creative.creative_changes
      refute done?(:onboarding_first_creative)
    end

    test "untracked legacy ownership still counts" do
      Current.reset
      root = Creative.create!(user: @user, description: "Legacy")
      child = Creative.create!(parent: root, description: "Legacy child")
      assert_equal 0, child.reload.revision
      assert_empty child.creative_changes
      assert done?(:onboarding_first_creative)
      assert done?(:onboarding_sub_creative)
    end

    test "edited legacy rows without creation evidence do not prove owner creation" do
      Current.reset
      root = Creative.create!(user: @user, description: "Legacy")
      Creatives::History.track(actor: @user, origin: :editor) { root.update!(description: "Edited legacy") }
      assert_operator root.reload.revision, :>, 0
      refute done?(:onboarding_first_creative)
    end

    test "another actor's creation and the user's edits do not count" do
      child = create_shared_child(actor: @owner)
      Creatives::History.track(actor: @user, origin: :editor) { child.update!(description: "Edited") }

      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)
    end

    test "unapplied creation history does not count" do
      child = create_shared_child
      change_set = child.creative_changes.find_by!(operation: "create").change_set
      %w[draft rejected reverted].each do |status|
        change_set.update!(status: status)
        refute done?(:onboarding_first_creative), status
        refute done?(:onboarding_sub_creative), status
      end
    end

    test "system and sync history do not count as a human creation" do
      child = create_shared_child
      change_set = child.creative_changes.find_by!(operation: "create").change_set
      %w[agent sync system].each do |actor_kind|
        change_set.update!(actor_kind: actor_kind)
        refute done?(:onboarding_first_creative), actor_kind
        refute done?(:onboarding_sub_creative), actor_kind
      end
    end

    test "a child moved to the root still counts by its creation snapshot" do
      child = create_shared_child
      child.update_columns(parent_id: nil)

      assert done?(:onboarding_first_creative)
      assert done?(:onboarding_sub_creative)
    end

    test "inbox creation history does not count" do
      Creatives::History.track(actor: @user, origin: :editor) { Creative.inbox_for(@user) }

      refute done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)
    end

    test "a root created for another owner counts only as a first creative" do
      Creatives::History.track(actor: @user, origin: :editor) do
        Creative.create!(user: @owner, description: "Delegated root")
      end

      assert done?(:onboarding_first_creative)
      refute done?(:onboarding_sub_creative)
    end
  end
end
