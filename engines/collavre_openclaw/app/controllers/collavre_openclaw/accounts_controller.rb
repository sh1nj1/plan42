module CollavreOpenclaw
  class AccountsController < ApplicationController
    before_action :require_authentication
    before_action :set_ai_user
    before_action :set_account, only: [ :edit, :update, :destroy ]
    before_action :authorize_admin!

    def new
      @account = OpenclawAccount.new(user: @ai_user)
    end

    def create
      @account = OpenclawAccount.new(account_params)
      @account.user = @ai_user

      if @account.save
        redirect_to collavre.edit_user_path(@ai_user),
                    notice: I18n.t("collavre_openclaw.accounts.created")
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @account.update(account_params)
        redirect_to collavre.edit_user_path(@ai_user),
                    notice: I18n.t("collavre_openclaw.accounts.updated")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @account.destroy
      redirect_to collavre.edit_user_path(@ai_user),
                  notice: I18n.t("collavre_openclaw.accounts.deleted")
    end

    private

    def set_ai_user
      @ai_user = Collavre.user_class.find(params[:user_id] || params.dig(:openclaw_account, :user_id))
    rescue ActiveRecord::RecordNotFound
      redirect_to collavre.users_path, alert: I18n.t("collavre_openclaw.errors.user_not_found")
    end

    def set_account
      @account = @ai_user.openclaw_account
      unless @account
        redirect_to new_account_path(user_id: @ai_user.id),
                    alert: I18n.t("collavre_openclaw.errors.account_not_found")
      end
    end

    def authorize_admin!
      unless Current.user&.system_admin? || Current.user == @ai_user.creator
        redirect_to collavre.root_path, alert: I18n.t("collavre_openclaw.errors.unauthorized")
      end
    end

    def account_params
      params.require(:openclaw_account).permit(:gateway_url, :api_token, :channel_id, :description)
    end
  end
end
