class UsersController < ApplicationController
  allow_unauthenticated_access only: [ :new, :create, :exists ]

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
          CreativeShare.create!(creative: invitation.creative, user: @user, permission: invitation.permission)
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

  def search
    term = params[:q].to_s.strip.downcase
    users = User.where("email LIKE ?", "#{term}%").limit(5)
    render json: users.map { |u| { email: u.email, avatar_url: view_context.user_avatar_url(u, size: 20) } }
  end

  # List all users
  def index
    @users = User.includes(:sessions, :devices)
  end

  # Show a single user
  def show
    @user = User.find(params[:id])
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
