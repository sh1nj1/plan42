# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class ProgressTrackerTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Learner", email: "tracker@example.com", password: "password")
        @seeded_agent = User.create!(
          name: "Onboarding helper", email: "onboarding-helper@example.com", password: "password",
          llm_vendor: "openai", searchable: true
        )
        @session = Seeder.new(user: @user).call
        @first, @second = @session.practice_creatives.order(:id)
      end

      test "advances only after the matching successful domain events" do
        assert_equal "progress", current_step

        ProgressTracker.record(user: @user, event: :progress_changed, creative: @first, before_progress: 0)
        assert_equal "progress", current_step

        added = Creative.create!(user: @user, parent: @session.root, description: "Added practice item")
        ProgressTracker.record(user: @user, event: :creative_created, creative: added)

        assert_equal added.id, Session.for_user(@user).added_practice_creative_id
        assert_equal "progress", current_step

        added.update!(progress: 1.0)
        ProgressTracker.record(user: @user, event: :progress_changed, creative: added, before_progress: 0)
        assert_equal "editor", current_step

        ProgressTracker.record(user: @user, event: :description_changed, creative: @second,
                               before_description: @second.description)
        assert_equal "editor", current_step

        @second.update!(description: "Changed")
        ProgressTracker.record(user: @user, event: :description_changed, creative: @second,
                               before_description: "Before")
        assert_equal "comment", current_step
      end

      test "requires a public human comment before an AI mention" do
        add_and_complete_practice_item(@user, @session)
        @second.update!(description: "Changed")
        ProgressTracker.record(user: @user, event: :description_changed, creative: @second, before_description: "Before")

        private_comment = Comment.create!(creative: @second, user: @user, content: "Hidden", private: true)
        ProgressTracker.record(user: @user, event: :comment_created, comment: private_comment)
        assert_equal "comment", current_step

        public_comment = Comment.create!(creative: @second, user: @user, content: "Hello")
        ProgressTracker.record(user: @user, event: :comment_created, comment: public_comment)
        assert_equal "mention", current_step
      end

      test "requires a mentionable AI agent with feedback access" do
        advance_to_mention_step
        agent = User.create!(
          name: "Unavailable helper",
          email: "unavailable-helper@example.com",
          password: "password",
          llm_vendor: "openai"
        )
        comment = Comment.create!(creative: @second, user: @user, content: "@Unavailable helper: Please help")

        ProgressTracker.record(user: @user, event: :agent_mentioned, comment: comment)
        assert_equal "mention", current_step

        CreativeShare.create!(creative: @session.root, user: agent, permission: :feedback)
        CreativeSharesCache.find_or_create_by!(creative: @session.root, user: agent, permission: :feedback)

        ProgressTracker.record(user: @user, event: :agent_mentioned, comment: comment)
        assert_equal "complete", current_step
      end

      test "uses the seeded agent share to complete the mention step" do
        @user = User.create!(name: "Seeded agent learner", email: "seeded-agent-learner@example.com", password: "password")
        @session = Seeder.new(user: @user).call
        @first, @second = @session.practice_creatives.order(:id)
        share = CreativeShare.find_by!(creative: @session.root)
        agent = share.user
        Creatives::PermissionCacheBuilder.propagate_share(share)
        advance_to_mention_step
        comment = Comment.create!(creative: @second, user: @user, content: "@#{agent.name}: Please help")

        ProgressTracker.record(user: @user, event: :agent_mentioned, comment: comment)

        assert_equal "complete", current_step
      end

      test "finishes after a public comment when the core deployment has no agent" do
        user = User.create!(name: "Core-only learner", email: "core-only-tracker@example.com", password: "password")
        User.stub(:accessible_ai_agents_for, User.none) do
          session = Seeder.new(user: user).call
          first, second = session.practice_creatives.order(:id)

          add_and_complete_practice_item(user, session)
          second.update!(description: "Changed")
          ProgressTracker.record(user: user, event: :description_changed, creative: second, before_description: "Before")
          comment = Comment.create!(creative: second, user: user, content: "Hello")
          ProgressTracker.record(user: user, event: :comment_created, comment: comment)

          assert_equal "complete", Session.for_user(user).data["current_step"]
        end
      end

      private

      def current_step
        Session.for_user(@user).data["current_step"]
      end

      def advance_to_mention_step
        add_and_complete_practice_item(@user, @session)
        @second.update!(description: "Changed")
        ProgressTracker.record(user: @user, event: :description_changed, creative: @second, before_description: "Before")
        comment = Comment.create!(creative: @second, user: @user, content: "Hello")
        ProgressTracker.record(user: @user, event: :comment_created, comment: comment)
        assert_equal "mention", current_step
      end

      def add_and_complete_practice_item(user, session)
        added = Creative.create!(user: user, parent: session.root, description: "Added practice item")
        ProgressTracker.record(user: user, event: :creative_created, creative: added)
        added.update!(progress: 1.0)
        ProgressTracker.record(user: user, event: :progress_changed, creative: added, before_progress: 0)
        added
      end
    end
  end
end
