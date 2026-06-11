# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Mobile
        # Active work list for the home screen — number, label, agent, status —
        # so the user can SEE which "1번/2번" maps to what before speaking.
        class SessionsController < BaseController
          def index
            tasks = running_tasks.to_a
            payload = tasks.map do |task|
              ref = registry.ref_for_session(task.topic_id, label: label_for_topic(task.topic_id))
              {
                ref: ref.ref_number,
                label: ref.label,
                agent_name: task.agent&.name,
                status: task.status,
                topic_id: task.topic_id
              }
            end

            # Read-only: do NOT reconcile here — only agent_events#index, which
            # sees the full live set (approvals + sessions), may resolve refs.
            render json: payload
          end
        end
      end
    end
  end
end
