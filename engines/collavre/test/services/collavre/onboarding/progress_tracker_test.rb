# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class ProgressTrackerTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Learner", email: "tracker@example.com", password: "password")
        @session = Seeder.new(user: @user).call
        @first, @second = @session.practice_creatives.order(:id)
      end

      test "advances only after the matching successful domain events" do
        ProgressTracker.record(user: @user, event: :ui)
        assert_equal "progress", current_step

        ProgressTracker.record(user: @user, event: :progress_changed, creative: @second, before_progress: 0)
        assert_equal "progress", current_step

        @first.update!(progress: 1.0)
        ProgressTracker.record(user: @user, event: :progress_changed, creative: @first, before_progress: 0)
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
        ProgressTracker.record(user: @user, event: :ui)
        @first.update!(progress: 1.0)
        ProgressTracker.record(user: @user, event: :progress_changed, creative: @first, before_progress: 0)
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

      private

      def current_step
        Session.for_user(@user).data["current_step"]
      end

      def advance_to_mention_step
        ProgressTracker.record(user: @user, event: :ui)
        @first.update!(progress: 1.0)
        ProgressTracker.record(user: @user, event: :progress_changed, creative: @first, before_progress: 0)
        @second.update!(description: "Changed")
        ProgressTracker.record(user: @user, event: :description_changed, creative: @second, before_description: "Before")
        comment = Comment.create!(creative: @second, user: @user, content: "Hello")
        ProgressTracker.record(user: @user, event: :comment_created, comment: comment)
        assert_equal "mention", current_step
      end
    end
  end
end
