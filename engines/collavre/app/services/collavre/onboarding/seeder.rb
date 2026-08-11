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
          return session if session&.practice_creatives_intact?
          return clean_up_session! if session

          # A deleted onboarding root cannot be resumed. Remove any practice
          # items reparented by the normal destroy flow before marking the
          # session complete, so they do not become permanent workspace roots.
          return clean_up_session! if user.onboarding_seeded_at?
          return mark_existing_workspace_complete! if existing_workspace? && !force?

          session_id = SecureRandom.uuid
          root = Creative.create!(user: user, description: t(:root), progress: 0.0)
          first = Creative.create!(user: user, parent: root, description: t(:progress_practice), progress: 0.0,
                                   data: { "onboarding" => { "session_id" => session_id } })
          second = Creative.create!(user: user, parent: root, description: t(:editor_practice), progress: 0.0,
                                    data: { "onboarding" => { "session_id" => session_id } })
          agent = share_available_agent!(root)
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

        share = CreativeShare.find_or_create_by!(creative: root, user: agent) do |share|
          share.shared_by = user
          share.permission = :feedback
        end
        # The regular CreativeShare callback refreshes this cache asynchronously.
        # The onboarding mention step may be reached before that job runs, so seed
        # its permission synchronously after all practice children exist.
        Creatives::PermissionCacheBuilder.propagate_share(share)
        agent
      end

      def t(key)
        I18n.t("collavre.onboarding.seed.#{key}", locale: user.locale.presence || I18n.default_locale)
      end

      def mark_existing_workspace_complete!
        user.update!(onboarding_completed_at: Time.current)
        nil
      end

      def clean_up_session!
        CompletionService.new(user: user).call
        mark_existing_workspace_complete!
      end
    end
  end
end
