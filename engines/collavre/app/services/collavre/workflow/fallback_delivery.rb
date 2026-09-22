# frozen_string_literal: true

module Collavre
  module Workflow
    # The child owns its ordinary recipient set even after partial publication.
    # Queue acknowledgement is durable before moving on to another recipient.
    # Queue acceptance and this database write cannot be atomic: a crash in
    # between remains a best-effort delivery boundary, not exactly-once I/O.
    class FallbackDelivery
      def initialize(row, token:)
        @row = row
        @token = token
        @plan = row.ordinary_delivery
      end

      def pending_agents
        return unless @plan

        users = User.where(id: @plan.keys).index_by { |agent| agent.id.to_s }
        missing = @plan.select { |id, state| state == "pending" && !users.key?(id) }
        save!(@plan.merge(missing.transform_values { "rejected" })) if missing.any?
        @plan.filter_map do |id, state|
          next unless state == "pending"
          users[id]
        end
      end

      def capture!(agents)
        return if @plan

        save!(agents.to_h { |agent| [ agent.id.to_s, "pending" ] })
      end

      def permitted?(agent)
        raise ActiveRecord::StaleObjectError unless @row.owned(@token).where(state: "delivering").exists?

        # Revalidate access and assignment without re-running matching or floor
        # selection. The worker retains its ordinary admission checks as well.
        allowed = agent.ai_user? && Safety.new(@row.execution).permitted?(agent) &&
          Orchestration::Matcher.permits_assignment?(@row.context, agent)
        record!(agent, "rejected") unless allowed
        allowed
      end

      def record!(agent, state)
        save!(@plan.merge(agent.id.to_s => state))
      end

      private

      def save!(plan)
        changed = @row.owned(@token).where(state: "delivering").update_all(ordinary_delivery: plan)
        raise ActiveRecord::StaleObjectError unless changed == 1

        @plan = plan
      end
    end
  end
end
