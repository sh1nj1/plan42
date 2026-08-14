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

      def self.canonical_mention_resolves_to?(agent)
        return false if agent.blank? || agent.name.blank?

        User.where("LOWER(name) = ?", agent.name.downcase).limit(2).count == 1 &&
          MentionParser.resolve_user("@#{agent.name}:")&.id == agent.id
      end

      def self.onboarding_root(creatives, session_id: nil)
        return Array(creatives).find { |creative| onboarding_root?(creative, session_id) } unless creatives.respond_to?(:where)

        scope = creatives.where(onboarding_scenario_key_present_sql)
        scope = scope.where(onboarding_session_id_equals_sql, session_id) if session_id.present?
        scope.to_a.find { |creative| onboarding_root?(creative, session_id) }
      end
      private_class_method :onboarding_root

      def self.onboarding_root?(creative, session_id)
        onboarding = creative.data.is_a?(Hash) ? creative.data["onboarding"] : nil
        creative.user&.onboarding_seeded_at? && onboarding.is_a?(Hash) && onboarding["seeded"] == true &&
          registered_scenario?(onboarding["scenario_key"]) && onboarding["session_id"].present? &&
          (session_id.blank? || onboarding["session_id"] == session_id)
      end
      private_class_method :onboarding_root?

      def self.registered_scenario?(key)
        ScenarioRegistry.all.any? { |scenario| scenario.key.to_s == key.to_s }
      end
      private_class_method :registered_scenario?

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
        ScenarioRegistry.fetch(
          data.fetch("scenario_key"),
          include_agent_mention: agent_mention_available?
        )
      end

      def current_step
        step = scenario.steps.find { |candidate| candidate.key.to_s == data["current_step"].to_s }
        return step if step

        complete_removed_mention_step!
        nil
      end

      def practice_creative_ids
        Array(data["practice_creative_ids"]).map(&:to_i)
      end

      def practice_creatives
        Creative.where(id: practice_creative_ids)
      end

      def added_practice_creative_id
        creative_id = data["added_practice_creative_id"]&.to_i
        return unless creative_id&.positive?
        return creative_id if Creative.active.where(id: creative_id, parent_id: root.id).exists?

        clear_missing_added_practice_creative!(creative_id)
        nil
      end

      def practice_creatives_intact?
        expected_ids = practice_creative_ids.uniq.sort
        expected_ids.size == 2 && !root.archived? &&
          practice_creatives.active.where(parent_id: root.id).pluck(:id).sort == expected_ids
      end

      def includes?(creative)
        creative && (creative.id == root.id || practice_creative_ids.include?(creative.id))
      end

      def anchor_key(step = current_step)
        target_creative(step)&.id
      end

      def navigation_path(step = current_step, script_name: nil)
        target = case step&.key
        when :progress, :editor then root
        when :comment, :mention then target_creative(step)
        end
        return unless target

        Collavre::Engine.routes.url_helpers.creatives_path(
          id: target.id,
          open_comments: true,
          script_name: script_name
        )
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

      def agent_mention_available?
        return false unless data["agent_mention_enabled"] == true

        agent = mention_agent
        agent&.ai_user? && root.has_permission?(agent, :feedback) &&
          self.class.canonical_mention_resolves_to?(agent)
      end

      def complete_removed_mention_step!
        return unless data["current_step"] == "mention" && !agent_mention_available?

        update! do |onboarding|
          onboarding["current_step"] = "complete"
        end
      end

      # New sessions persist the helper selected by Seeder, keeping the polling
      # endpoint to a single user/cache lookup. The cache-backed fallback keeps
      # sessions created before that field existed resumable without scanning all
      # globally searchable agents.
      def mention_agent
        agent_id = data["agent_mention_agent_id"]
        return User.find_by(id: agent_id) if agent_id.present?

        User.mentionable_for(root).ai_agents
          .joins(:creative_shares_caches)
          .where(creative_shares_caches: { creative_id: root.id })
          .where("creative_shares_caches.permission >= ?", CreativeShare.permissions[:feedback])
          .first
      end

      def target_creative(step)
        case step&.target
        when :root
          root
        when :first_practice
          added_practice_creative || practice_creatives.find_by(id: practice_creative_ids.first)
        when :second_practice then practice_creatives.find_by(id: practice_creative_ids.second)
        end
      end

      def added_practice_creative
        root.children.find_by(id: added_practice_creative_id) if added_practice_creative_id
      end

      # A learner can move or delete the item selected for the required
      # add-and-complete action. Keeping its stale id makes the guide point at a
      # seeded item that cannot satisfy ProgressTracker, so return to Add instead.
      def clear_missing_added_practice_creative!(creative_id)
        update! do |onboarding|
          onboarding.delete("added_practice_creative_id") if onboarding["added_practice_creative_id"].to_i == creative_id
        end
      end
    end
  end
end
