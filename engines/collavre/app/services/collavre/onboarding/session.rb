# frozen_string_literal: true

module Collavre
  module Onboarding
    class Session
      def self.for_user(user)
        root = onboarding_root(user&.creatives)
        root && new(root)
      end

      def self.for_creative(creative)
        return unless creative

        data = creative.data.is_a?(Hash) ? creative.data["onboarding"] : nil
        return unless data.is_a?(Hash) && data["session_id"].present?

        root = onboarding_root(creative.user.creatives, session_id: data["session_id"])
        root && new(root)
      end

      def self.onboarding_root(creatives, session_id: nil)
        records = creatives.respond_to?(:reload) ? creatives.reload : Array(creatives)
        records.find do |creative|
          onboarding = creative.data.is_a?(Hash) ? creative.data["onboarding"] : nil
          onboarding.is_a?(Hash) && onboarding["scenario_key"].present? &&
            (session_id.blank? || onboarding["session_id"] == session_id)
        end
      end
      private_class_method :onboarding_root

      def initialize(root)
        @root = root
      end

      attr_reader :root

      def data
        root.data.fetch("onboarding")
      end

      def session_id
        data.fetch("session_id")
      end

      def scenario
        ScenarioRegistry.fetch(data.fetch("scenario_key"))
      end

      def current_step
        scenario.steps.find { |step| step.key.to_s == data["current_step"].to_s }
      end

      def practice_creative_ids
        Array(data["practice_creative_ids"]).map(&:to_i)
      end

      def practice_creatives
        Creative.where(id: practice_creative_ids)
      end

      def includes?(creative)
        creative && (creative.id == root.id || practice_creative_ids.include?(creative.id))
      end

      def update!(attributes = {})
        root.with_lock do
          onboarding = root.reload.data.fetch("onboarding").deep_dup
          yield onboarding if block_given?
          onboarding.merge!(attributes.stringify_keys) unless block_given?
          root.update!(data: root.data.merge("onboarding" => onboarding))
        end
      end
    end
  end
end
