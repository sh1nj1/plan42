module CollavreOpenclaw
  class AccountsController < ApplicationController
    before_action :require_authentication
    before_action :set_ai_user
    before_action :set_account, only: [ :edit, :update, :destroy, :test_connection, :clear_token ]
    before_action :authorize_admin!

    def new
      @account = OpenclawAccount.new(user: @ai_user)
    end

    def create
      @account = OpenclawAccount.new(account_params)
      @account.user = @ai_user

      if @account.save
        redirect_to collavre.edit_ai_user_path(@ai_user),
                    notice: I18n.t("collavre_openclaw.accounts.created")
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @account.update(account_params)
        redirect_to collavre.edit_ai_user_path(@ai_user),
                    notice: I18n.t("collavre_openclaw.accounts.updated")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @account.destroy
      redirect_to collavre.edit_ai_user_path(@ai_user),
                  notice: I18n.t("collavre_openclaw.accounts.deleted")
    end

    def test_connection
      result = @account.test_connection

      respond_to do |format|
        format.html do
          if result[:success]
            redirect_to collavre_openclaw.edit_account_path(@account),
                        notice: I18n.t("collavre_openclaw.test_connection.success", details: result[:details])
          else
            redirect_to collavre_openclaw.edit_account_path(@account),
                        alert: I18n.t("collavre_openclaw.test_connection.failure",
                                      message: result[:message],
                                      details: result[:details])
          end
        end
        format.json { render json: result }
      end
    end

    def clear_token
      @account.clear_token!
      redirect_to collavre_openclaw.edit_account_path(@account),
                  notice: I18n.t("collavre_openclaw.accounts.token_cleared")
    end

    private

    def set_ai_user
      # For actions with :id param (edit, update, destroy, test_connection, clear_token),
      # get user from the account if user_id is not provided
      if params[:id].present? && params[:user_id].blank?
        account = OpenclawAccount.find_by(id: params[:id])
        if account
          @ai_user = account.user
          return
        end
      end

      @ai_user = Collavre.user_class.find(params[:user_id] || params.dig(:openclaw_account, :user_id))
    rescue ActiveRecord::RecordNotFound
      redirect_to collavre.users_path, alert: I18n.t("collavre_openclaw.errors.user_not_found")
    end

    def set_account
      @account = @ai_user&.openclaw_account || OpenclawAccount.find_by(id: params[:id])
      unless @account
        redirect_to collavre_openclaw.new_account_path(user_id: @ai_user&.id),
                    alert: I18n.t("collavre_openclaw.errors.account_not_found")
      end
    end

    def authorize_admin!
      unless Current.user&.system_admin? || Current.user == @ai_user.creator
        redirect_to collavre.root_path, alert: I18n.t("collavre_openclaw.errors.unauthorized")
      end
    end

    def account_params
      params.require(:openclaw_account).permit(:gateway_url, :api_token)
    end
  end
end
