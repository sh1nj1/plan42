module Collavre
  module UsersController::AiUserManagement
    extend ActiveSupport::Concern

    included do
      before_action :set_user_for_ai_actions, only: [ :edit_ai, :update_ai ]
      before_action :verify_ai_user, only: [ :edit_ai, :update_ai ]
      before_action :verify_ai_user_authorization, only: [ :update_ai ]
    end

    def new_ai
      @available_tools = load_available_tools

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
        tools: params[:tools] || [],
        searchable: searchable,
        email_verified_at: Time.current,
        created_by_id: Current.user.id,
        routing_expression: params[:routing_expression]
      )
      @user.agent_conf = params[:agent_conf] if @user.respond_to?(:agent_conf=) && params[:agent_conf].present?

      if @user.save
        Collavre::Contact.ensure(user: Current.user, contact_user: @user)
        share_ai_agent_to_creative(@user, params[:creative_id])
        redirect_to user_path(Current.user, tab: "contacts"), notice: I18n.t("collavre.users.create_ai.success")
      else
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        @available_tools = load_available_tools
        render :new_ai, status: :unprocessable_entity
      end
    end

    def edit_ai
      @available_tools = load_available_tools
      @agent_context_creatives = load_agent_context_creatives
    end

    def update_ai
      ai_params = params.require(:user).permit(:name, :system_prompt, :llm_vendor, :llm_model, :llm_api_key, :gateway_url, :searchable, :routing_expression, :agent_conf, tools: [])

      # Merge agent_context_creative_ids into agent_conf YAML
      if params[:user][:agent_context_creative_ids].present?
        creative_ids = JSON.parse(params[:user][:agent_context_creative_ids]) rescue []
        creative_ids = Array(creative_ids).map(&:to_i).reject(&:zero?)

        conf = @user.parsed_agent_conf
        conf["context"] ||= {}
        conf["context"]["creative_ids"] = creative_ids
        ai_params[:agent_conf] = conf.to_yaml
      end

      if @user.update(ai_params)
        redirect_to edit_ai_user_path(@user), notice: I18n.t("collavre.users.update_ai.success")
      else
        @available_tools = load_available_tools
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        render :edit_ai, status: :unprocessable_entity
      end
    end

    private

    def load_agent_context_creatives
      ids = @user.agent_context_creative_ids
      return [] if ids.empty?

      creatives_by_id = Collavre::Creative.where(id: ids).index_by(&:id)
      ids.filter_map do |id|
        c = creatives_by_id[id]
        next unless c

        { id: c.id, description: c.creative_snippet }
      end
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
