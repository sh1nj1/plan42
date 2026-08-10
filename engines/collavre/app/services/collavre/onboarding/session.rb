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

        scope = creatives.where(onboarding_scenario_key_present_sql)
        scope = scope.where(onboarding_session_id_equals_sql, session_id) if session_id.present?
        scope.first
      end
      private_class_method :onboarding_root

      def self.onboarding_root?(creative, session_id)
        onboarding = creative.data.is_a?(Hash) ? creative.data["onboarding"] : nil
        onboarding.is_a?(Hash) && onboarding["scenario_key"].present? &&
          (session_id.blank? || onboarding["session_id"] == session_id)
      end
      private_class_method :onboarding_root?

      def self.onboarding_scenario_key_present_sql
        if Creative.connection.adapter_name.match?(/sqlite/i)
          "json_extract(data, '$.onboarding.scenario_key') IS NOT NULL"
        else
          "data -> 'onboarding' ->> 'scenario_key' IS NOT NULL"
        end
      end
      private_class_method :onboarding_scenario_key_present_sql

      def self.onboarding_session_id_equals_sql
        if Creative.connection.adapter_name.match?(/sqlite/i)
          "json_extract(data, '$.onboarding.session_id') = ?"
        else
          "data -> 'onboarding' ->> 'session_id' = ?"
        end
      end
      private_class_method :onboarding_session_id_equals_sql

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

      def anchor_key(step = current_step)
        target_creative(step)&.id
      end

      def navigation_path(step = current_step)
        return unless step&.key == :progress

        Collavre::Engine.routes.url_helpers.creatives_path(id: root.id)
      end

      def update!(attributes = {})
        root.with_lock do
          onboarding = root.reload.data.fetch("onboarding").deep_dup
          yield onboarding if block_given?
          onboarding.merge!(attributes.stringify_keys) unless block_given?
          root.update!(data: root.data.merge("onboarding" => onboarding))
        end
      end

      private

      def target_creative(step)
        case step&.target
        when :root then root
        when :first_practice then practice_creatives.find_by(id: practice_creative_ids.first)
        when :second_practice then practice_creatives.find_by(id: practice_creative_ids.second)
        end
      end
    end
  end
end
