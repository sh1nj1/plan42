class UsersController < ApplicationController
  allow_unauthenticated_access only: [ :new, :create ]

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    if @user.save
      session.delete(:return_to_after_authenticating)
      redirect_to new_session_path, notice: t("users.new.success_sign_up")
    else
      render :new, status: :unprocessable_entity
    end
  end

  # List all users
  def index
    @users = User.all
  end

  # Show a single user
  def show
    @user = User.find(params[:id])
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
    params.require(:user).permit(:email, :password, :password_confirmation)
  end
end
