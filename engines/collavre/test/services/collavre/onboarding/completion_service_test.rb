require "test_helper"

module Collavre
  module Onboarding
    class CompletionServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
        Creative.onboarding_guides.where(user: @user).destroy_all
        Creative.inbox_for(@user)
        @root = Seeder.call(user: @user)
        @session_id = @root.onboarding_metadata["session_id"]
      end

      test "removes every session item even after cards and practices move" do
        external = Creative.create!(user: @user, description: "Keep me")
        card = @root.children.second
        practice = card.children.sole
        card.update!(parent: external)
        practice.update!(parent: external)

        assert CompletionService.call(user: @user, session_id: @session_id)

        assert_empty session_items
        assert Creative.exists?(external.id)
        assert_not_nil @user.reload.onboarding_completed_at
      end

      test "reset cleanup does not mark onboarding completed" do
        assert CompletionService.call(user: @user, session_id: @session_id, mark_completed: false)

        assert_empty session_items
        assert_nil @user.reload.onboarding_completed_at
      end

      test "completion removes the welcome message that links to the deleted guide" do
        notification_key = Seeder.welcome_notification_key(@user)
        assert Comment.exists?(notification_key: notification_key)

        assert CompletionService.call(user: @user, session_id: @session_id)

        assert_not Comment.exists?(notification_key: notification_key)
      end

      test "rejects a blank session" do
        assert_not CompletionService.call(user: @user, session_id: nil)
        assert Creative.exists?(@root.id)
      end

      private

      def session_items
        Creative.where(user: @user).select do |creative|
          creative.onboarding_metadata&.dig("session_id") == @session_id
        end
      end
    end
  end
end
