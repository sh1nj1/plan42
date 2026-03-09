# frozen_string_literal: true

module CollavreCompletionApi
  module Api
    module V1
      class ModelsController < BaseController
        def index
          ai_agents = Collavre::User.accessible_ai_agents_for(current_user)

          models = ai_agents.map do |agent|
            {
              id: agent_model_id(agent),
              object: "model",
              created: agent.created_at.to_i,
              owned_by: "collavre",
              meta: {
                name: agent.name,
                llm_vendor: agent.llm_vendor,
                llm_model: agent.llm_model
              }
            }
          end

          render json: { object: "list", data: models }
        end
      end
    end
  end
end
