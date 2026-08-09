# frozen_string_literal: true

module Collavre
  module Onboarding
    class Seeder
      VERSION = 1
      WELCOME_NOTIFICATION_KEY_PREFIX = "onboarding_welcome_v1_user_"

      def self.call(user:, script_name: nil)
        new(user: user, script_name: script_name).call
      end

      def self.reset!(user:)
        User.transaction do
          Creative.onboarding_guides.where(user: user).find_each do |creative|
            Collavre::Creatives::DestroyService.new(
              creative: creative,
              user: user,
              delete_with_children: true
            ).call
          end

          user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
        end
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

            seeded_creative = create_guide!
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

      def create_guide!
        root = Creative.create!(
          user: user,
          description: I18n.t("collavre.onboarding.guide.title"),
          data: { "kind" => Creative::ONBOARDING_KIND, "version" => VERSION },
          progress: 0.0
        )

        I18n.t("collavre.onboarding.guide.steps").each_value do |description|
          Creative.create!(user: user, parent: root, description: description, progress: 0.0)
        end

        root
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

      def welcome_notification_key
        "#{WELCOME_NOTIFICATION_KEY_PREFIX}#{user.id}"
      end

      def onboarding_locale
        locale = user.locale.presence&.to_sym
        I18n.available_locales.include?(locale) ? locale : I18n.locale
      end
    end
  end
end
