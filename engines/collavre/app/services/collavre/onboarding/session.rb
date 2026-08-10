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
        return Array(creatives).find { |creative| onboarding_root?(creative, session_id) } unless creatives.respond_to?(:where)

        scope = creatives.where("#{onboarding_value('scenario_key')} IS NOT NULL")
        scope = scope.where("#{onboarding_value('session_id')} = ?", session_id) if session_id.present?
        scope.first
      end
      private_class_method :onboarding_root

      def self.onboarding_root?(creative, session_id)
        onboarding = creative.data.is_a?(Hash) ? creative.data["onboarding"] : nil
        onboarding.is_a?(Hash) && onboarding["scenario_key"].present? &&
          (session_id.blank? || onboarding["session_id"] == session_id)
      end
      private_class_method :onboarding_root?

      def self.onboarding_value(key)
        if Creative.connection.adapter_name.match?(/sqlite/i)
          "json_extract(data, '$.onboarding.#{key}')"
        else
          "data -> 'onboarding' ->> '#{key}'"
        end
      end
      private_class_method :onboarding_value

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
