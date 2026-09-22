# frozen_string_literal: true

module Collavre
  module Quota
    class PendingDispatch
      def self.call(agent, event_name, context, deadline)
        agent.with_lock do
          return unless Workflow::TaskAdmission.permitted?(context, agent)
          return if Workflow::TaskAdmission.duplicate_dispatch?(context, agent)

          attributes = Workflow::TaskAdmission.attributes(context, agent).merge(
            name: "Response to #{event_name}", agent: agent, status: "pending",
            trigger_event_name: event_name, trigger_event_payload: context,
            creative_id: context.dig("creative", "id"), topic_id: context.dig("topic", "id")
          )
          task = Task.create!(attributes)
          Orchestration::TaskResumer.suspend!(task, reason: "quota", resume_not_before: deadline)
          task
        end
      end
    end
  end
end
