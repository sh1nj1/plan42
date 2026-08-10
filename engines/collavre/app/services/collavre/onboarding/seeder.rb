# frozen_string_literal: true

module Collavre
  module Onboarding
    class Seeder
      def initialize(user:, force: false)
        @user = user
        @force = force
      end

      def call
        return Session.for_user(user) if user.onboarding_seeded_at?
        return mark_existing_workspace_complete! if existing_workspace? && !force?

        user.with_lock do
          return Session.for_user(user) if user.onboarding_seeded_at?

          session_id = SecureRandom.uuid
          root = Creative.create!(user: user, description: t(:root), progress: 0.0)
          first = Creative.create!(user: user, parent: root, description: t(:progress_practice), progress: 0.0,
                                   data: { "onboarding" => { "session_id" => session_id } })
          second = Creative.create!(user: user, parent: root, description: t(:editor_practice), progress: 0.0,
                                    data: { "onboarding" => { "session_id" => session_id } })
          root.update!(data: {
            "onboarding" => {
              "session_id" => session_id,
              "scenario_key" => "first_steps",
              "current_step" => "tree_node",
              "steps" => {},
              "practice_creative_ids" => [ first.id, second.id ],
              "chat_autoopen_pending" => true
            }
          })
          user.update!(onboarding_seeded_at: Time.current, onboarding_completed_at: nil)
          Session.new(root)
        end
      end

      private

      attr_reader :user

      def force?
        @force
      end

      def existing_workspace?
        user.creatives.where(parent_id: nil).to_a.any? { |creative| !creative.inbox? }
      end

      def t(key)
        I18n.t("collavre.onboarding.seed.#{key}", locale: user.locale.presence || I18n.default_locale)
      end

      def mark_existing_workspace_complete!
        user.update!(onboarding_completed_at: Time.current)
        nil
      end
    end
  end
end
