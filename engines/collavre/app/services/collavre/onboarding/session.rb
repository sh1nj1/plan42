# frozen_string_literal: true

module Collavre
  module Onboarding
    class Session
      def self.for_user(user)
        root = user.creatives.where(parent_id: nil).find do |creative|
          creative.data.is_a?(Hash) && creative.data.dig("onboarding", "session_id").present?
        end
        root && new(root)
      end

      def self.for_creative(creative)
        return unless creative

        data = creative.data.is_a?(Hash) ? creative.data["onboarding"] : nil
        return unless data.is_a?(Hash) && data["session_id"].present?

        new(creative)
      end

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
