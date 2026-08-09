# frozen_string_literal: true

module Collavre
  module Onboarding
    class Seeder
      VERSION = 2
      WELCOME_NOTIFICATION_KEY_PREFIX = "onboarding_welcome_v1_user_"
      STEP_KEYS = %w[create_edit progress_rollup creative_chat mention_agent].freeze
      SEEDED_PRACTICE_STEPS = STEP_KEYS.excluding("create_edit").freeze

      def self.call(user:, script_name: nil)
        new(user: user, script_name: script_name).call
      end

      def self.reset!(user:)
        User.transaction do
          session_ids = Creative.where(user: user).filter_map { |creative| creative.onboarding_metadata&.dig("session_id") }.uniq
          session_ids.each do |session_id|
            CompletionService.call(user: user, session_id: session_id, mark_completed: false)
          end

          # Version 1 guides did not carry durable session metadata.
          Creative.onboarding_guides.where(user: user).find_each do |creative|
            Collavre::Creatives::DestroyService.new(
              creative: creative,
              user: user,
              delete_with_children: true,
              onboarding_cleanup: true
            ).call
          end

          user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
        end
      end

      def self.welcome_notification_key(user)
        "#{WELCOME_NOTIFICATION_KEY_PREFIX}#{user.id}"
      end

      def initialize(user:, script_name: nil)
        @user = user
        @script_name = script_name
      end

      def call
        return if user.nil? || user.ai_user?

        seeded_creative = nil
        I18n.with_locale(onboarding_locale) do
          user.with_lock do
            next if user.onboarding_seeded_at.present?

            practice_agent = eligible_practice_agent
            seeded_creative = create_guide!(step_keys: step_keys_for(practice_agent))
            grant_practice_agent_access!(seeded_creative, practice_agent)
            create_or_update_welcome_message!(seeded_creative)
            user.update!(onboarding_seeded_at: Time.current, onboarding_completed_at: nil)
          end
        end
        seeded_creative
      rescue StandardError => error
        Rails.logger.error(
          "[Collavre::Onboarding::Seeder] Failed to seed onboarding for user #{user&.id}: " \
          "#{error.class}: #{error.message}"
        )
        nil
      end

      private

      attr_reader :user, :script_name

      def create_guide!(step_keys:)
        session_id = SecureRandom.uuid
        root = Creative.create!(
          user: user,
          description: I18n.t("collavre.onboarding.guide.title"),
          data: onboarding_data(session_id: session_id, role: "root").merge(
            "kind" => Creative::ONBOARDING_KIND,
            "version" => VERSION,
            "source" => { "type" => Creative::ONBOARDING_KIND }
          ),
          progress: 0.0
        )

        step_keys.each do |step_key|
          create_step!(root: root, session_id: session_id, step_key: step_key)
        end

        root
      end

      def create_step!(root:, session_id:, step_key:)
        card = FeatureCardRegistry.find(step_key)
        raise KeyError, "Missing onboarding feature card: #{step_key}" unless card&.visible_on?(:onboarding)

        card_creative = Creative.create!(
          user: user,
          parent: root,
          description: fallback_description(card),
          data: onboarding_data(
            session_id: session_id,
            role: "card",
            step_key: step_key,
            feature_key: step_key,
            status: "pending"
          ).merge("source" => { "type" => Creative::ONBOARDING_KIND }),
          progress: 0.0
        )
        return unless SEEDED_PRACTICE_STEPS.include?(step_key)

        practice = Creative.create!(
          user: user,
          parent: card_creative,
          description: I18n.t("collavre.onboarding.practice.#{step_key}"),
          data: onboarding_data(session_id: session_id, role: "practice", step_key: step_key),
          progress: 0.0
        )
        update_onboarding_data!(card_creative, "target_creative_id" => practice.id)
      end

      def onboarding_data(session_id:, role:, step_key: nil, feature_key: nil, status: nil)
        metadata = { "session_id" => session_id, "role" => role }
        metadata["step_key"] = step_key if step_key
        metadata["feature_key"] = feature_key if feature_key
        metadata["status"] = status if status
        { "onboarding" => metadata }
      end

      def update_onboarding_data!(creative, attributes)
        data = creative.data.deep_dup
        data["onboarding"].merge!(attributes.stringify_keys)
        creative.update!(data: data)
      end

      def fallback_description(card)
        helpers = ActionController::Base.helpers
        helpers.content_tag(:p) do
          helpers.safe_join([
            helpers.content_tag(:strong, "#{card.icon} #{I18n.t(card.title_key)}"),
            helpers.tag.br,
            I18n.t(card.description_key)
          ])
        end
      end

      def create_or_update_welcome_message!(root)
        inbox = Creative.inbox_for(user)
        topic = inbox.system_topic(fallback_user: user)
        routes = Collavre::Engine.routes.url_helpers
        comment = Comment.find_or_initialize_by(notification_key: welcome_notification_key)
        comment.assign_attributes(
          creative: inbox,
          topic: topic,
          user: nil,
          content: I18n.t(
            "collavre.onboarding.welcome",
            onboarding_path: routes.creatives_path(id: root.id, script_name: script_name),
            features_path: routes.features_path(script_name: script_name)
          ),
          skip_default_user: true,
          skip_dispatch: true,
          skip_link_preview: true
        )
        comment.save!
      end

      def grant_practice_agent_access!(root, agent)
        return unless agent

        mention_card = root.children.find do |child|
          child.onboarding_metadata&.dig("step_key") == "mention_agent"
        end
        practice = Creative.find(mention_card.onboarding_metadata.fetch("target_creative_id"))
        share = CreativeShare.find_or_create_by!(creative: practice, user: agent) do |new_share|
          new_share.permission = :feedback
          new_share.shared_by = user
        end

        # The mention step is visible as soon as seeding returns, so its grant
        # cannot wait for the normal after-commit authz job.
        Creatives::PermissionCacheBuilder.propagate_share(share)
      end

      def eligible_practice_agent
        User.accessible_ai_agents_for(user).first
      end

      def step_keys_for(practice_agent)
        practice_agent ? STEP_KEYS : STEP_KEYS.excluding("mention_agent")
      end

      def welcome_notification_key
        self.class.welcome_notification_key(user)
      end

      def onboarding_locale
        locale = user.locale.presence&.to_sym
        I18n.available_locales.include?(locale) ? locale : I18n.locale
      end
    end
  end
end
