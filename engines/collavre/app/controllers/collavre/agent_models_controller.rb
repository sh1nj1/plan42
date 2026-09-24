module Collavre
  class AgentModelsController < ApplicationController
    before_action :set_authorized_agent

    def show
      render_editor
    end

    def update
      model = params.require(:user).permit(:llm_model)[:llm_model].to_s.strip
      if model.blank? || model.length > LlmModel::MAX_NAME_LENGTH
        @agent.errors.add(:llm_model, :invalid)
      else
        @saved = save_model(model)
      end
      render_editor(status: @agent.errors.any? ? :unprocessable_entity : :ok)
    end

    private

    def save_model(model)
      User.transaction do
        next false unless @agent.update(model_attributes(model))

        LlmModel.remember!(vendor: @agent.llm_vendor, name: model, creator: Current.user)
        true
      end
    end

    def model_attributes(model)
      attributes = { llm_model: model }
      if @agent.cli_proxy_agent? && !CliProxy::RunOptions.efforts_for(model).include?(@agent.reasoning_effort)
        attributes[:reasoning_effort] = nil
      end
      attributes
    end

    def set_authorized_agent
      @agent = User.find(params[:user_id])
      head :forbidden unless @agent.ai_user? &&
        (Current.user.system_admin? || @agent.created_by_id == Current.user.id)
    end

    def render_editor(status: :ok)
      response.headers["Cache-Control"] = "private, no-store"
      render partial: "collavre/agent_models/editor", status: status
    end
  end
end
