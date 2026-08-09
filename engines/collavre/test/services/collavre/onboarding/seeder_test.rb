require "test_helper"

module Collavre
  module Onboarding
    class SeederTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil, locale: "ko")
        Creative.onboarding_guides.where(user: @user).destroy_all
        Creative.inbox_for(@user)
      end

      test "seeds a localized guide and one inbox welcome message atomically" do
        root = nil

        assert_difference -> { Creative.count }, 7 do
          assert_difference -> { onboarding_welcome_messages.count }, 1 do
            root = Seeder.call(user: @user)
          end
        end

        assert_predicate root, :onboarding_guide?
        assert_equal I18n.t("collavre.onboarding.guide.title", locale: :ko), root.description
        assert_equal I18n.t("collavre.onboarding.guide.steps", locale: :ko).values, root.children.map(&:description)
        assert_equal 6, root.children.count
        assert_in_delta 0.0, root.progress
        assert_not_nil @user.reload.onboarding_seeded_at
        assert_nil @user.onboarding_completed_at

        welcome = onboarding_welcome_messages.sole
        assert_nil welcome.user_id
        assert_equal Creative::SYSTEM_TOPIC_NAME, welcome.topic.name
        assert_includes welcome.content, collavre.creatives_path(id: root.id)
        assert_includes welcome.content, collavre.features_path
      end

      test "does nothing after onboarding has already been seeded" do
        first_root = Seeder.call(user: @user)

        assert_no_difference -> { Creative.count } do
          assert_no_difference -> { Comment.count } do
            assert_nil Seeder.call(user: @user)
          end
        end

        assert_equal first_root, Creative.onboarding_guides.find_by(user: @user)
      end

      test "rolls back and returns nil when guide creation fails" do
        create_failure = lambda do |*args, **kwargs|
          attributes = kwargs.presence || args.first
          raise ActiveRecord::RecordInvalid if attributes[:data]&.dig("kind") == Creative::ONBOARDING_KIND

          Creative.create!(*args, **kwargs)
        end

        assert_no_difference -> { Creative.count } do
          Creative.stub(:create!, create_failure) do
            assert_nil Seeder.call(user: @user)
          end
        end

        assert_nil @user.reload.onboarding_seeded_at
      end

      test "does not seed AI users" do
        ai_user = users(:ai_bot)
        ai_user.update!(onboarding_seeded_at: nil)

        assert_no_difference -> { Creative.count } do
          assert_nil Seeder.call(user: ai_user)
        end

        assert_nil ai_user.reload.onboarding_seeded_at
      end

      test "reset removes the current guide and allows a fresh guide without duplicating the welcome" do
        original_root = Seeder.call(user: @user)
        original_welcome = onboarding_welcome_messages.sole
        @user.update!(onboarding_completed_at: Time.current)

        Seeder.reset!(user: @user)

        assert_not Creative.exists?(original_root.id)
        assert_nil @user.reload.onboarding_seeded_at
        assert_nil @user.onboarding_completed_at

        replacement_root = Seeder.call(user: @user)
        assert_not_equal original_root.id, replacement_root.id
        assert_equal 1, onboarding_welcome_messages.count
        assert_equal original_welcome.id, onboarding_welcome_messages.sole.id
        assert_includes onboarding_welcome_messages.sole.content, collavre.creatives_path(id: replacement_root.id)
      end

      private

      def onboarding_welcome_messages
        Comment.where(notification_key: "#{Seeder::WELCOME_NOTIFICATION_KEY_PREFIX}#{@user.id}")
      end

      def collavre
        Collavre::Engine.routes.url_helpers
      end
    end
  end
end
