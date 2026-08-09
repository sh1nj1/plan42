require "test_helper"

module Collavre
  module Onboarding
    class ProgressTrackerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil, locale: "en")
        users(:ai_bot).update!(created_by_id: @user.id)
        Creative.onboarding_guides.where(user: @user).destroy_all
        Creative.inbox_for(@user)
        @root = Seeder.call(user: @user)
      end

      test "creating a child starts create-edit but does not complete it" do
        card = card_for("create_edit")
        practice = Creative.create!(user: @user, parent: card, description: "Draft")

        tracked_card = ProgressTracker.creative_created(creative: practice, user: @user)

        assert_equal card, tracked_card
        assert practice.reload.onboarding_practice?
        assert_equal "in_progress", card.reload.onboarding_metadata["status"]
        assert_equal practice.id, card.onboarding_metadata["target_creative_id"]
        assert_in_delta 0.0, practice.progress
        assert_in_delta 0.0, @root.reload.progress
      end

      test "editing the created child completes create-edit and rolls progress up" do
        card = card_for("create_edit")
        practice = Creative.create!(user: @user, parent: card, description: "Draft")
        ProgressTracker.creative_created(creative: practice, user: @user)
        practice.update!(description: "Edited draft")

        completed_card = ProgressTracker.creative_updated(
          creative: practice,
          user: @user,
          changed_attributes: [ "description" ]
        )

        assert_equal card, completed_card
        assert_equal "completed", card.reload.onboarding_metadata["status"]
        assert_in_delta 1.0, practice.reload.progress
        assert_in_delta 1.0, card.reload.progress
        assert_in_delta 0.25, @root.reload.progress
      end

      test "a real progress toggle completes the progress step idempotently" do
        card = card_for("progress_rollup")
        practice = card.children.sole
        practice.update!(progress: 1.0)

        first = ProgressTracker.creative_updated(
          creative: practice,
          user: @user,
          changed_attributes: [ "progress" ]
        )
        completed_at = first.reload.onboarding_metadata["completed_at"]
        second = ProgressTracker.creative_updated(
          creative: practice,
          user: @user,
          changed_attributes: [ "progress" ]
        )

        assert_equal card, second
        assert_equal completed_at, second.reload.onboarding_metadata["completed_at"]
        assert_in_delta 0.25, @root.reload.progress
      end

      test "the current user's public comment completes chat" do
        card = card_for("creative_chat")
        practice = card.children.sole
        comment = practice.comments.create!(
          user: @user,
          content: "Hello",
          private: false,
          skip_dispatch: true
        )

        ProgressTracker.comment_created(comment: comment, user: @user)

        assert_equal "completed", card.reload.onboarding_metadata["status"]
        assert_in_delta 1.0, practice.reload.progress
      end

      test "another user's comment and a private comment are ignored" do
        card = card_for("creative_chat")
        practice = card.children.sole
        other_comment = practice.comments.create!(
          user: users(:two),
          content: "Other",
          private: false,
          skip_dispatch: true
        )
        private_comment = practice.comments.create!(
          user: @user,
          content: "Private",
          private: true,
          skip_dispatch: true
        )

        ProgressTracker.comment_created(comment: other_comment, user: @user)
        ProgressTracker.comment_created(comment: private_comment, user: @user)

        assert_equal "pending", card.reload.onboarding_metadata["status"]
        assert_in_delta 0.0, practice.reload.progress
      end

      test "only a resolved AI mention completes the mention step" do
        card = card_for("mention_agent")
        practice = card.children.sole
        plain = practice.comments.create!(
          user: @user,
          content: "No mention",
          private: false,
          skip_dispatch: true
        )
        ProgressTracker.comment_created(comment: plain, user: @user)
        assert_equal "pending", card.reload.onboarding_metadata["status"]

        agent = users(:ai_bot)
        mentioned = practice.comments.create!(
          user: @user,
          content: "@#{agent.name}: help me",
          private: false,
          skip_dispatch: true
        )
        ProgressTracker.comment_created(comment: mentioned, user: @user)

        metadata = card.reload.onboarding_metadata
        assert_equal "completed", metadata["status"]
        assert_equal agent.id, metadata["invoked_agent_id"]
        assert_equal "waiting", metadata["response_status"]
      end

      test "an AI mention without feedback access does not complete the mention step" do
        card = card_for("mention_agent")
        practice = card.children.sole
        agent = User.create!(
          name: "Unshared AI",
          email: "unshared-ai-#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash"
        )
        comment = practice.comments.create!(
          user: @user,
          content: "@#{agent.name}: help me",
          private: false,
          skip_dispatch: true
        )

        assert_nil ProgressTracker.comment_created(comment: comment, user: @user)
        assert_equal "pending", card.reload.onboarding_metadata["status"]
      end

      test "an invoked agent reply clears the waiting state" do
        card = card_for("mention_agent")
        practice = card.children.sole
        agent = users(:ai_bot)
        mention = practice.comments.create!(
          user: @user,
          content: "@#{agent.name}: help me",
          private: false,
          skip_dispatch: true
        )
        ProgressTracker.comment_created(comment: mention, user: @user)
        reply = practice.comments.create!(
          user: agent,
          content: "Here is help",
          private: false,
          skip_dispatch: true
        )

        tracked_card = ProgressTracker.agent_replied(comment: reply)

        assert_equal card, tracked_card
        metadata = card.reload.onboarding_metadata
        assert_equal "responded", metadata["response_status"]
        assert_not_nil metadata["responded_at"]
      end

      test "tracking is disabled after onboarding completes" do
        card = card_for("progress_rollup")
        practice = card.children.sole
        @user.update!(onboarding_completed_at: Time.current)
        practice.update!(progress: 1.0)

        assert_nil ProgressTracker.creative_updated(
          creative: practice,
          user: @user,
          changed_attributes: [ "progress" ]
        )
        assert_equal "pending", card.reload.onboarding_metadata["status"]
      end

      private

      def card_for(step_key)
        @root.children.find { |creative| creative.onboarding_metadata["step_key"] == step_key }
      end
    end
  end
end
