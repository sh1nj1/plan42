module Collavre
  module UsersController::AiUserManagement
    extend ActiveSupport::Concern

    included do
      before_action :set_user_for_ai_actions, only: [ :edit_ai, :update_ai ]
      before_action :verify_ai_user, only: [ :edit_ai, :update_ai ]
      before_action :verify_ai_user_authorization, only: [ :edit_ai, :update_ai ]
    end

    def new_ai
      @available_tools = load_available_tools
      @llm_models = Collavre::LlmModel.suggestions
      @agent_gateways = chat_capable_agent_gateways(Current.user)

      if params[:copy_from].present?
        source = Collavre::User.find_by(id: params[:copy_from])
        if source&.ai_user? && source.created_by_id == Current.user.id
          @copy_source = source
          @copy_name = "#{source.name} (copy)"
        end
      end
    end

    def create_ai
      ai_id = params[:ai_id].to_s.strip.downcase
      email = "#{ai_id}@ai.local"
      searchable = ActiveModel::Type::Boolean.new.cast(params.fetch(:searchable, false))

      @user = Collavre::User.new(
        name: params[:name],
        email: email,
        password: SecureRandom.hex(36),
        system_prompt: params[:system_prompt],
        llm_vendor: params[:llm_vendor].presence || "google",
        llm_model: params[:llm_model],
        llm_api_key: params[:llm_api_key],
        gateway_url: params[:gateway_url],
        agent_gateway: selected_agent_gateway,
        tools: params[:tools] || [],
        searchable: searchable,
        email_verified_at: Time.current,
        created_by_id: Current.user.id,
        routing_expression: params[:routing_expression]
      )
      @user.agent_conf = params[:agent_conf] if @user.respond_to?(:agent_conf=) && params[:agent_conf].present?

      saved = Collavre::User.transaction do
        next false unless @user.save

        remember_llm_model(@user)
        Collavre::Contact.ensure(user: Current.user, contact_user: @user)
        share_ai_agent_to_creative(@user, params[:creative_id])
        true
      end

      if saved
        redirect_to user_path(Current.user, tab: "contacts"), notice: I18n.t("collavre.users.create_ai.success")
      else
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        @available_tools = load_available_tools
        @llm_models = Collavre::LlmModel.suggestions
        @agent_gateways = chat_capable_agent_gateways(Current.user)
        render :new_ai, status: :unprocessable_entity
      end
    end

    def edit_ai
      @available_tools = load_available_tools
      @llm_models = Collavre::LlmModel.suggestions
      @agent_gateways = editable_agent_gateways(@user)
      @has_stored_llm_api_key = @user.llm_api_key.present?
    end

    def update_ai
      ai_params = params.require(:user).permit(:name, :system_prompt, :llm_vendor, :llm_model, :llm_api_key, :clear_llm_api_key, :gateway_url, :agent_gateway_id, :searchable, :routing_expression, :agent_conf, tools: [])
      effective_vendor = ai_params[:llm_vendor].presence || @user.llm_vendor
      if effective_vendor == "cli_proxy" && ai_params.key?(:agent_gateway_id)
        gateways = gateway_owner_for(@user).owned_agent_gateways
        gateway = if ai_params[:agent_gateway_id].to_s == @user.agent_gateway_id.to_s
          gateways.find_by(id: ai_params[:agent_gateway_id])
        else
          gateways.active.find_by(id: ai_params[:agent_gateway_id])
        end
        ai_params[:agent_gateway_id] = gateway&.id
      elsif ai_params.key?(:llm_vendor)
        ai_params[:agent_gateway_id] = nil
      end
      clear_llm_api_key = ActiveModel::Type::Boolean.new.cast(ai_params.delete(:clear_llm_api_key))
      @has_stored_llm_api_key = @user.llm_api_key.present?
      @clear_llm_api_key = clear_llm_api_key

      if clear_llm_api_key
        ai_params[:llm_api_key] = nil
      elsif ai_params[:llm_api_key].blank?
        ai_params.delete(:llm_api_key)
      end

      updated = Collavre::User.transaction do
        next false unless @user.update(ai_params)

        if @user.saved_change_to_llm_vendor? || @user.saved_change_to_llm_model?
          remember_llm_model(@user)
        end
        true
      end

      if updated
        redirect_to edit_ai_user_path(@user), notice: I18n.t("collavre.users.update_ai.success")
      else
        @available_tools = load_available_tools
        @llm_models = Collavre::LlmModel.suggestions
        @agent_gateways = editable_agent_gateways(@user)
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        render :edit_ai, status: :unprocessable_entity
      end
    end

    private

    def remember_llm_model(user)
      Collavre::LlmModel.remember!(
        vendor: user.llm_vendor,
        name: user.llm_model,
        creator: Current.user
      )
    end

    def load_available_tools
      Collavre::McpService.available_tools(Current.user).map do |tool|
        {
          name: tool[:name],
          description: tool[:description],
          parameters: tool[:params]
        }
      end
    end

    def selected_agent_gateway
      return unless params[:llm_vendor] == "cli_proxy"

      Current.user.owned_agent_gateways.active.find_by(id: params[:agent_gateway_id])
    end

    def gateway_owner_for(agent)
      agent.creator || Current.user
    end

    def editable_agent_gateways(agent)
      gateways = gateway_owner_for(agent).owned_agent_gateways
      selected_gateway = gateways.find_by(id: agent.agent_gateway_id)
      (chat_capable_agent_gateways(gateway_owner_for(agent)) + [ selected_gateway ]).compact.uniq.sort_by(&:name)
    end

    def chat_capable_agent_gateways(owner)
      owner.owned_agent_gateways.active.order(:name).select(&:chat_capable?)
    end

    def set_user_for_ai_actions
      @user = Collavre::User.find(params[:id])
    end

    def verify_ai_user
      unless @user.ai_user?
        redirect_to user_path(@user), alert: I18n.t("collavre.users.edit_ai.not_an_ai")
      end
    end

    def verify_ai_user_authorization
      allowed = Current.user.system_admin? ||
                (@user.ai_user? && @user.created_by_id == Current.user.id)

      unless allowed
        fallback = user_path(Current.user, tab: "contacts")
        redirect_back fallback_location: fallback, alert: I18n.t("collavre.users.destroy.not_authorized")
      end
    end

    def share_ai_agent_to_creative(user, creative_id)
      return if creative_id.blank?

      creative = Collavre::Creative.find_by(id: creative_id)
      return unless creative&.has_permission?(Current.user, :admin)

      Collavre::CreativeShare.find_or_create_by!(
        creative: creative,
        user: user
      ) do |share|
        share.shared_by = Current.user
        share.permission = :feedback
      end
    end
  end
end
