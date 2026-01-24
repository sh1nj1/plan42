module Collavre
  class UsersController < ApplicationController
    allow_unauthenticated_access only: %i[new create exists]
    before_action -> { enforce_auth_provider!(:email) }, only: [ :new, :create ]
    before_action :require_system_admin!, only: [ :index, :grant_system_admin, :revoke_system_admin ]

    def new
      @user = Collavre::User.new
      if params[:invite_token].present?
        @invitation = Collavre::Invitation.find_by_token_for(:invite, params[:invite_token])
        @user.email = @invitation&.email
      end
    end

    def create
      @user = Collavre::User.new(user_params)
      Collavre::Invitation.transaction do
        if params[:invite_token].present?
          invitation = Collavre::Invitation.find_by_token_for(:invite, params[:invite_token])
          if invitation
            @invitation = invitation
            @user.email = invitation.email
          end
        end
        if @user.save
          if invitation
            invitation.update(accepted_at: Time.current)
            Collavre::CreativeShare.create!(
              creative: invitation.creative,
              user: @user,
              permission: invitation.permission,
              shared_by: invitation.inviter
            )
            Collavre::Contact.ensure(user: invitation.inviter, contact_user: @user)
            invitation.creative.create_linked_creative_for_user(@user)
          end
          Collavre::EmailVerificationMailer.verify(@user).deliver_later
          session.delete(:return_to_after_authenticating)
          redirect_to new_session_path, notice: I18n.t("users.new.success_sign_up")
        else
          render :new, status: :unprocessable_entity
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        flash.now[:alert] = I18n.t("invites.invalid")
        render :new, status: :unprocessable_entity
      end
    end

    def exists
      user = Collavre::User.find_by(email: params[:email])
      render json: { exists: user.present? }
    end

    def new_ai
      @available_tools = load_available_tools
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
        llm_vendor: "google",
        llm_model: params[:llm_model],
        llm_api_key: params[:llm_api_key],
        tools: params[:tools] || [],
        searchable: searchable,
        email_verified_at: Time.current,
        created_by_id: Current.user.id,
        routing_expression: params[:routing_expression]
      )

      if @user.save
        Collavre::Contact.ensure(user: Current.user, contact_user: @user)
        redirect_to user_path(Current.user, tab: "contacts"), notice: I18n.t("users.create_ai.success")
      else
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        @available_tools = load_available_tools
        render :new_ai, status: :unprocessable_entity
      end
    end

    def edit_ai
      @user = Collavre::User.find(params[:id])
      unless @user.ai_user?
        redirect_to user_path(@user), alert: I18n.t("users.edit_ai.not_an_ai")
        return
      end

      @available_tools = load_available_tools
    end

    def update_ai
      @user = Collavre::User.find(params[:id])
      unless @user.ai_user?
        redirect_to user_path(@user), alert: I18n.t("users.edit_ai.not_an_ai")
        return
      end

      allowed = Current.user.system_admin? ||
                (@user.ai_user? && @user.created_by_id == Current.user.id)

      unless allowed
        fallback = user_path(Current.user, tab: "contacts")
        redirect_back fallback_location: fallback, alert: I18n.t("users.destroy.not_authorized")
        return
      end

      ai_params = params.require(:user).permit(:name, :system_prompt, :llm_model, :llm_api_key, :searchable, :routing_expression, tools: [])

      if @user.update(ai_params)
        redirect_to edit_ai_user_path(@user), notice: I18n.t("users.update_ai.success")
      else
        @available_tools = load_available_tools
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        render :edit_ai, status: :unprocessable_entity
      end
    end

    def search
      term = params[:q].to_s.strip.downcase

      if term.blank? && params[:scope] != "contacts"
        return render json: []
      end

      creative = Collavre::Creative.find_by(id: params[:creative_id])

      if creative.present? && !creative.has_permission?(Current.user, :read)
        head :forbidden and return
      end

      scope = if params[:scope] == "contacts" && Current.user
        Current.user.contact_users
      else
        Collavre::User.mentionable_for(creative)
      end

      users = scope
      if term.present?
        users = users.where("LOWER(users.email) LIKE :term OR LOWER(users.name) LIKE :term", term: "#{term}%")
      end

      limit = params[:limit].to_i
      limit = 20 if limit <= 0
      limit = 50 if limit > 50

      user_ids = users.select(:id).distinct.limit(limit).pluck(:id)
      users = Collavre::User.where(id: user_ids)
      render json: users.map { |u| { id: u.id, name: u.display_name, email: u.email, avatar_url: view_context.user_avatar_url(u, size: 20) } }
    end

    def index
      @users = Collavre::User.includes(:sessions, :devices)
    end

    def show
      @user = Collavre::User.find(params[:id])
      @active_tab = params[:tab].presence || "profile"
      if Current.user
        prepare_contacts
      else
        @contacts = Collavre::Contact.none
        @contact_page = 1
        @total_contact_pages = 1
        @last_login_map = {}
        @shared_by_me = {}
        @shared_with_me = {}
      end
    end

    def destroy
      @user = Collavre::User.find(params[:id])

      if @user == Current.user
        redirect_to users_path, alert: I18n.t("users.destroy.cannot_delete_self")
        return
      end

      allowed = Current.user.system_admin? ||
                (@user.ai_user? && @user.created_by_id == Current.user.id)

      unless allowed
        fallback = user_path(Current.user, tab: "contacts")
        redirect_back fallback_location: fallback, alert: I18n.t("users.destroy.not_authorized")
        return
      end

      if @user.destroy
        fallback = Current.user.system_admin? ? users_path : user_path(Current.user, tab: "contacts")
        redirect_back fallback_location: fallback, notice: I18n.t("users.destroy.success")
      else
        redirect_to users_path, alert: I18n.t("users.destroy.failure")
      end
    end

    def grant_system_admin
      @user = Collavre::User.find(params[:id])

      if @user.update(system_admin: true)
        redirect_to users_path, notice: I18n.t("users.system_admin.granted")
      else
        redirect_to users_path, alert: I18n.t("users.system_admin.failed")
      end
    end

    def revoke_system_admin
      @user = Collavre::User.find(params[:id])

      if @user.update(system_admin: false)
        redirect_to users_path, notice: I18n.t("users.system_admin.revoked")
      else
        redirect_to users_path, alert: I18n.t("users.system_admin.failed")
      end
    end

    def update
      @user = Collavre::User.find(params[:id])
      if @user.update(profile_params)
        redirect_to user_path(@user), notice: I18n.t("users.profile_updated")
      else
        render :show, status: :unprocessable_entity
      end
    end

    def notification_settings
      if Current.user.update(notification_settings_params)
        head :no_content
      else
        render json: { errors: Current.user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def edit_password
      @user = Collavre::User.find(params[:id])
    end

    def passkeys
      @user = Collavre::User.find(params[:id])

      unless @user == Current.user || Current.user.system_admin?
        redirect_to user_path(Current.user), alert: I18n.t("users.destroy.not_authorized")
      end
    end

    def update_password
      @user = Collavre::User.find(params[:id])
      if @user.authenticate(params[:user][:current_password])
        if @user.update(user_params)
          redirect_to user_path(@user), notice: I18n.t("users.password_updated")
        else
          flash.now[:alert] = I18n.t("users.password_update_failed")
          render :edit_password, status: :unprocessable_entity
        end
      else
        @user.errors.add(:current_password, I18n.t("users.current_password_incorrect"))
        flash.now[:alert] = I18n.t("users.password_update_failed")
        render :edit_password, status: :unprocessable_entity
      end
    end

    private

    def load_available_tools
      return [] unless defined?(RailsMcpEngine)

      RailsMcpEngine::Engine.build_tools!
      tools = Tools::MetaToolService.new.call(action: "list", tool_name: nil, query: nil, arguments: nil)

      tool_list = Array(tools[:tools])
      filtered_tools = McpService.filter_tools(tool_list, Current.user)

      filtered_tools.map do |tool|
        {
          name: tool[:name],
          description: tool[:description],
          parameters: tool[:params]
        }
      end
    rescue StandardError => e
      Rails.logger.error("Failed to load MCP tools: #{e.message}")
      []
    end

    def prepare_contacts
      per_page = 10
      @contact_page = [ params[:contact_page].to_i, 1 ].max

      creative_shares = Collavre::CreativeShare.arel_table
      creatives = Collavre::Creative.arel_table

      user_creative_origins_sql = Collavre::Creative
        .where(user_id: Current.user.id)
        .select("COALESCE(origin_id, id) AS origin_id")
        .to_sql

      shared_by_me_scope = Collavre::CreativeShare
        .joins(:creative)
        .where.not(permission: Collavre::CreativeShare.permissions[:no_access])
        .where(
          creative_shares[:shared_by_id].eq(Current.user.id)
            .or(
              creative_shares[:shared_by_id].eq(nil).and(creatives[:user_id].eq(Current.user.id))
            )
            .or(
              creatives[:id].in(Arel.sql("(#{user_creative_origins_sql})"))
            )
        )

      shared_with_me_scope = Collavre::CreativeShare
        .joins(:creative)
        .where(user_id: Current.user.id)
        .where.not(permission: Collavre::CreativeShare.permissions[:no_access])

      contact_ids_sql = [
        Current.user.contacts.select("contact_user_id AS user_id").to_sql,
        shared_by_me_scope.select("creative_shares.user_id AS user_id").to_sql,
        shared_with_me_scope.select("COALESCE(creative_shares.shared_by_id, creatives.user_id) AS user_id").to_sql
      ].join(" UNION ")

      contact_users_relation = Collavre::User.where(
        id: Collavre::User.from("(#{contact_ids_sql}) AS contact_ids").select(:user_id)
      )

      @total_contacts = contact_users_relation.count
      @total_contact_pages = [ (@total_contacts.to_f / per_page).ceil, 1 ].max
      paged_users = contact_users_relation
        .includes(avatar_attachment: :blob)
        .order(:name, :id)
        .offset((@contact_page - 1) * per_page)
        .limit(per_page)

      existing_contacts = Current.user.contacts.includes(contact_user: [ avatar_attachment: :blob ]).index_by(&:contact_user_id)
      @contacts = paged_users.map do |user|
        existing_contacts[user.id] || Collavre::Contact.new(user: Current.user, contact_user: user)
      end

      @last_login_map = Collavre::Session.where(user_id: paged_users.map(&:id)).group(:user_id).maximum(:updated_at)

      shares_from_me = shared_by_me_scope
        .where(user_id: paged_users.map(&:id))
        .includes(:creative)

      @shared_by_me = shares_from_me.group_by(&:user_id).transform_values { |shares| shares.map(&:creative) }

      shares_to_me = Collavre::CreativeShare
        .joins(:creative)
        .where(user_id: Current.user.id)
        .where.not(permission: Collavre::CreativeShare.permissions[:no_access])
        .where(
          creative_shares[:shared_by_id].in(paged_users.map(&:id))
            .or(creative_shares[:shared_by_id].eq(nil).and(creatives[:user_id].in(paged_users.map(&:id))))
        )
        .includes(:creative)

      @shared_with_me = shares_to_me.group_by(&:sharer_id)
                                    .transform_values { |shares| shares.map(&:creative) }
    end

    def user_params
      params.require(:user).permit(:email, :password, :password_confirmation, :name)
    end

    def profile_params
      params.require(:user).permit(
        :avatar,
        :avatar_url,
        :display_level,
        :completion_mark,
        :theme,
        :name,
        :notifications_enabled,
        :calendar_id,
        :timezone,
        :locale
      ).tap do |p|
        p[:locale] = normalize_supported_locale(p[:locale]) if p.key?(:locale)
      end
    end

    def notification_settings_params
      params.require(:user).permit(:notifications_enabled)
    end
  end
end
