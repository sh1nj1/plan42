module Collavre
  module UsersController::AdminOperations
    extend ActiveSupport::Concern

    USERS_PER_PAGE = 20

    included do
      before_action :require_system_admin!, only: [ :index, :grant_system_admin, :revoke_system_admin, :unlock, :lock ]
    end

    def index
      users = Collavre::User.all
      @total_user_pages = [ (users.count.to_f / USERS_PER_PAGE).ceil, 1 ].max
      @user_page = [ [ params[:page].to_i, 1 ].max, @total_user_pages ].min
      @users = users
        .includes(:sessions, :devices)
        .order(created_at: :desc, id: :desc)
        .offset((@user_page - 1) * USERS_PER_PAGE)
        .limit(USERS_PER_PAGE)
    end

    def destroy
      @user = Collavre::User.find(params[:id])

      if @user == Current.user
        redirect_to users_path, alert: I18n.t("collavre.users.destroy.cannot_delete_self")
        return
      end

      allowed = Current.user.system_admin? ||
                (@user.ai_user? && @user.created_by_id == Current.user.id)

      unless allowed
        fallback = user_path(Current.user, tab: "contacts")
        redirect_back fallback_location: fallback, alert: I18n.t("collavre.users.destroy.not_authorized")
        return
      end

      if @user.destroy
        fallback = Current.user.system_admin? ? users_path : user_path(Current.user, tab: "contacts")
        redirect_back fallback_location: fallback, notice: I18n.t("collavre.users.destroy.success")
      else
        redirect_to users_path, alert: I18n.t("collavre.users.destroy.failure")
      end
    end

    def grant_system_admin
      @user = Collavre::User.find(params[:id])

      if @user.update(system_admin: true)
        redirect_to users_path, notice: I18n.t("collavre.users.system_admin.granted")
      else
        redirect_to users_path, alert: I18n.t("collavre.users.system_admin.failed")
      end
    end

    def revoke_system_admin
      @user = Collavre::User.find(params[:id])

      if @user.update(system_admin: false)
        redirect_to users_path, notice: I18n.t("collavre.users.system_admin.revoked")
      else
        redirect_to users_path, alert: I18n.t("collavre.users.system_admin.failed")
      end
    end

    def unlock
      @user = Collavre::User.find(params[:id])
      @user.unlock_account!
      redirect_to users_path, notice: I18n.t("collavre.users.unlock.success", name: @user.display_name)
    end

    def lock
      @user = Collavre::User.find(params[:id])
      if @user == Current.user
        redirect_to users_path, alert: I18n.t("collavre.users.lock.cannot_lock_self")
        return
      end
      @user.lock_account!
      redirect_to users_path, notice: I18n.t("collavre.users.lock.success", name: @user.display_name)
    end
  end
end
