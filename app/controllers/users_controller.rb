class UsersController < ApplicationController
  allow_unauthenticated_access only: [ :new, :create, :exists ]
  before_action :require_system_admin!, only: [ :index, :grant_system_admin, :revoke_system_admin ]

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    Invitation.transaction do
      if params[:invite_token].present?
        invitation = Invitation.find_by_token_for(:invite, params[:invite_token])
        if invitation
          @invitation = invitation
          @user.email = invitation.email
        end
      end
      if @user.save
        if invitation
          invitation.update(accepted_at: Time.current)
          CreativeShare.create!(
            creative: invitation.creative,
            user: @user,
            permission: invitation.permission,
            shared_by: invitation.inviter
          )
          Contact.ensure(user: invitation.inviter, contact_user: @user)
          invitation.creative.create_linked_creative_for_user(@user)
        end
        UserMailer.email_verification(@user).deliver_now
        session.delete(:return_to_after_authenticating)
        redirect_to new_session_path, notice: t("users.new.success_sign_up")
      else
        render :new, status: :unprocessable_entity
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      flash.now[:alert] = t("invites.invalid")
      render :new, status: :unprocessable_entity
    end
  end

  def exists
    user = User.find_by(email: params[:email])
    render json: { exists: user.present? }
  end

  def new_ai
  end

  def create_ai
    ai_id = params[:ai_id].to_s.strip.downcase
    # Construct a dummy email for the AI user
    email = "#{ai_id}@ai.local"

    @user = User.new(
      name: params[:name],
      email: email,
      password: SecureRandom.hex(32), # Random password, impossible to login
      system_prompt: params[:system_prompt],
      llm_vendor: "google", # Default to google for now
      llm_model: params[:llm_model],
      llm_api_key: params[:llm_api_key],
      searchable: ActiveModel::Type::Boolean.new.cast(params[:searchable]),
      email_verified_at: Time.current, # Auto-verified
      created_by_id: Current.user.id
    )

    if @user.save
      Contact.ensure(user: Current.user, contact_user: @user)
      redirect_to user_path(Current.user, tab: "contacts"), notice: t("users.create_ai.success")
    else
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :new_ai, status: :unprocessable_entity
    end
  end

  def search
    term = params[:q].to_s.strip.downcase
    users = User.where(searchable: true)
                .where("LOWER(email) LIKE :term OR LOWER(name) LIKE :term", term: "#{term}%")
                .limit(5)
    render json: users.map { |u| { id: u.id, name: u.display_name, email: u.email, avatar_url: view_context.user_avatar_url(u, size: 20) } }
  end

  # List all users
  def index
    @users = User.includes(:sessions, :devices)
  end

  # Show a single user
  def show
    @user = User.find(params[:id])
    @active_tab = params[:tab].presence || "profile"
    if Current.user
      prepare_contacts
    else
      @contacts = Contact.none
      @contact_page = 1
      @total_contact_pages = 1
      @last_login_map = {}
      @shared_by_me = {}
      @shared_with_me = {}
    end
  end

  def destroy
    @user = User.find(params[:id])

    if @user == Current.user
      redirect_to users_path, alert: t("users.destroy.cannot_delete_self")
      return
    end

    allowed = Current.user.system_admin? ||
              (@user.ai_user? && @user.created_by_id == Current.user.id)

    unless allowed
      fallback = user_path(Current.user, tab: "contacts")
      redirect_back fallback_location: fallback, alert: t("users.destroy.not_authorized")
      return
    end

    if @user.destroy
      fallback = Current.user.system_admin? ? users_path : user_path(Current.user, tab: "contacts")
      redirect_back fallback_location: fallback, notice: t("users.destroy.success")
    else
      redirect_to users_path, alert: t("users.destroy.failure")
    end
  end

  def grant_system_admin
    @user = User.find(params[:id])

    if @user.update(system_admin: true)
      redirect_to users_path, notice: t("users.system_admin.granted")
    else
      redirect_to users_path, alert: t("users.system_admin.failed")
    end
  end

  def revoke_system_admin
    @user = User.find(params[:id])

    if @user.update(system_admin: false)
      redirect_to users_path, notice: t("users.system_admin.revoked")
    else
      redirect_to users_path, alert: t("users.system_admin.failed")
    end
  end

  def update
    @user = User.find(params[:id])
    if @user.update(profile_params)
      redirect_to user_path(@user), notice: t("users.profile_updated")
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

  # GET /users/:id/edit_password
  def edit_password
    @user = User.find(params[:id])
  end

  # PATCH /users/:id/update_password
  def update_password
    @user = User.find(params[:id])
    # Check current password
    if @user.authenticate(params[:user][:current_password])
      if @user.update(user_params)
        redirect_to user_path(@user), notice: t("users.password_updated")
      else
        flash.now[:alert] = t("users.password_update_failed")
        render :edit_password, status: :unprocessable_entity
      end
    else
      @user.errors.add(:current_password, t("users.current_password_incorrect"))
      flash.now[:alert] = t("users.password_update_failed")
      render :edit_password, status: :unprocessable_entity
    end
  end

  private
  def prepare_contacts
    per_page = 10
    @contact_page = [ params[:contact_page].to_i, 1 ].max

    # Collect all relevant user ids (contacts, people I've shared with, people who shared with me)
    creative_shares = CreativeShare.arel_table
    creatives = Creative.arel_table

    # Find origin creative IDs for creatives owned by current user
    # This includes both:
    # 1. Direct creatives (where origin_id IS NULL, so we use the creative's own id)
    # 2. Linked creatives (where origin_id points to the origin creative)
    user_creative_origins_sql = Creative
      .where(user_id: Current.user.id)
      .select("COALESCE(origin_id, id) AS origin_id")
      .to_sql

    shared_by_me_scope = CreativeShare
      .joins(:creative)
      .where.not(permission: CreativeShare.permissions[:no_access])
      .where(
        creative_shares[:shared_by_id].eq(Current.user.id)
          .or(
            creative_shares[:shared_by_id].eq(nil).and(creatives[:user_id].eq(Current.user.id))
          )
          .or(
            # Include shares on origin creatives where user owns a linked creative
            creatives[:id].in(Arel.sql("(#{user_creative_origins_sql})"))
          )
      )

    shared_with_me_scope = CreativeShare
      .joins(:creative)
      .where(user_id: Current.user.id)
      .where.not(permission: CreativeShare.permissions[:no_access])

    contact_ids_sql = [
      Current.user.contacts.select("contact_user_id AS user_id").to_sql,
      shared_by_me_scope.select("creative_shares.user_id AS user_id").to_sql,
      shared_with_me_scope.select("COALESCE(creative_shares.shared_by_id, creatives.user_id) AS user_id").to_sql
    ].join(" UNION ")

    contact_users_relation = User.where(
      id: User.from("(#{contact_ids_sql}) AS contact_ids").select(:user_id)
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
      existing_contacts[user.id] || Contact.new(user: Current.user, contact_user: user)
    end

    @last_login_map = Session.where(user_id: paged_users.map(&:id)).group(:user_id).maximum(:updated_at)

    shares_from_me = shared_by_me_scope
      .where(user_id: paged_users.map(&:id))
      .includes(creative: :rich_text_description)

    @shared_by_me = shares_from_me.group_by(&:user_id).transform_values { |shares| shares.map(&:creative) }

    shares_to_me = CreativeShare
      .joins(:creative)
      .where(user_id: Current.user.id)
      .where.not(permission: CreativeShare.permissions[:no_access])
      .where(
        creative_shares[:shared_by_id].in(paged_users.map(&:id))
          .or(creative_shares[:shared_by_id].eq(nil).and(creatives[:user_id].in(paged_users.map(&:id))))
      )
      .includes(creative: :rich_text_description)

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
