module Collavre
  module UsersController::ProfileAndSettings
    extend ActiveSupport::Concern

    def show
      @user = Collavre::User.find(params[:id])
      @active_tab = params[:tab].presence || "profile"
      @active_tab = "contacts" if @active_tab == "org_chart"
      @contacts_view = params[:contacts_view].presence || "list"
      if Current.user
        if @contacts_view == "org_chart"
          prepare_org_chart
        else
          prepare_contacts
        end
      else
        @contacts = []
        @shared_by_me = {}
        @shared_with_me = {}
        @total_contact_pages = 1
        @contact_page = 1
        @org_chart_roots = []
        @org_chart_shares = {}
        @org_chart_invitations = {}
        @org_chart_children = {}
        @org_chart_unassigned = []
      end
    end

    def update
      @user = Collavre::User.find(params[:id])
      if @user.update(profile_params)
        redirect_to user_path(@user), notice: I18n.t("collavre.users.profile_updated")
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
        redirect_to user_path(Current.user), alert: I18n.t("collavre.users.destroy.not_authorized")
      end
    end

    def update_password
      @user = Collavre::User.find(params[:id])
      if @user.authenticate(params[:user][:current_password])
        if @user.update(user_params)
          redirect_to user_path(@user), notice: I18n.t("collavre.users.password_updated")
        else
          flash.now[:alert] = I18n.t("collavre.users.password_update_failed")
          render :edit_password, status: :unprocessable_entity
        end
      else
        @user.errors.add(:current_password, I18n.t("collavre.users.current_password_incorrect"))
        flash.now[:alert] = I18n.t("collavre.users.password_update_failed")
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
end
