module Collavre
  module UsersController::AiUserManagement
    extend ActiveSupport::Concern

    AGENT_CONTEXT_ACTIONS = [ :add_agent_context_creative, :remove_agent_context_creative,
                              :reorder_agent_context_creatives ].freeze

    included do
      before_action :set_user_for_ai_actions, only: [ :edit_ai, :update_ai ] + AGENT_CONTEXT_ACTIONS
      before_action :verify_ai_user, only: [ :edit_ai, :update_ai ] + AGENT_CONTEXT_ACTIONS
      before_action :verify_ai_user_authorization, only: [ :update_ai ] + AGENT_CONTEXT_ACTIONS
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

      if @user.update(ai_params)
        redirect_to edit_ai_user_path(@user), notice: I18n.t("collavre.users.update_ai.success")
      else
        @available_tools = load_available_tools
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        render :edit_ai, status: :unprocessable_entity
      end
    end

    def add_agent_context_creative
      creative_id = params[:creative_id].to_i
      creative = Collavre::Creative.find_by(id: creative_id)

      unless creative
        render json: { error: I18n.t("collavre.users.edit_ai.agent_context_creative_not_found") }, status: :not_found
        return
      end

      # Check if agent has no_access — cannot add
      existing_share = Collavre::CreativeShare.find_by(creative: creative.effective_origin(Set.new), user: @user)
      if existing_share&.no_access?
        render json: { error: I18n.t("collavre.users.edit_ai.agent_context_creative_no_access") }, status: :forbidden
        return
      end

      # Auto-grant read permission if agent doesn't have it
      ensure_agent_read_permission(creative, @user)

      # Add to agent_conf
      current_ids = @user.agent_context_creative_ids
      unless current_ids.include?(creative_id)
        current_ids << creative_id
        update_agent_context_ids(current_ids)
      end

      render json: { id: creative.id, description: creative.creative_snippet }
    end

    def remove_agent_context_creative
      creative_id = params[:creative_id].to_i
      current_ids = @user.agent_context_creative_ids
      current_ids.delete(creative_id)
      update_agent_context_ids(current_ids)

      render json: { success: true }
    end

    def reorder_agent_context_creatives
      new_ids = Array(params[:creative_ids]).map(&:to_i).reject(&:zero?)
      update_agent_context_ids(new_ids)

      render json: { success: true }
    end

    private

    def ensure_agent_read_permission(creative, agent)
      origin = creative.effective_origin(Set.new)
      return if origin.has_permission?(agent, :read)

      Collavre::CreativeShare.find_or_create_by!(creative: origin, user: agent) do |share|
        share.shared_by = Current.user
        share.permission = :read
      end
    end

    def update_agent_context_ids(ids)
      conf = @user.parsed_agent_conf
      conf["context"] ||= {}
      conf["context"]["creative_ids"] = ids
      @user.update!(agent_conf: conf.to_yaml)
    end

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
