# frozen_string_literal: true

module Collavre
  module Onboarding
    class Seeder
      def initialize(user:, force: false)
        @user = user
        @force = force
      end

      def call
        user.with_lock do
          session = Session.for_user(user)
          return session if session

          # A deleted onboarding root cannot be resumed. Mark it complete rather
          # than silently creating another practice tree on a later visit.
          return mark_existing_workspace_complete! if user.onboarding_seeded_at?
          return mark_existing_workspace_complete! if existing_workspace? && !force?

          session_id = SecureRandom.uuid
          root = Creative.create!(user: user, description: t(:root), progress: 0.0)
          agent = share_available_agent!(root)
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
              # The core engine can run without an AI integration. Do not show
              # an impossible mention step when no usable agent is available.
              "agent_mention_enabled" => agent.present?,
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

      def share_available_agent!(root)
        agent = User.accessible_ai_agents_for(user).first
        return unless agent

        CreativeShare.find_or_create_by!(creative: root, user: agent) do |share|
          share.shared_by = user
          share.permission = :feedback
        end
        agent
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
